;;;; image.lisp --- The IMAGE wrapper, lifecycle, I/O and introspection

(in-package #:vips)

;;; ---------------------------------------------------------------------------
;;; The IMAGE wrapper type
;;;
;;; A libvips VipsImage is a GObject; we wrap the raw pointer in a struct so we
;;; can guard against use-after-free.
;;;
;;; Ownership is EXPLICIT and deterministic: an image is released by UNREF, by
;;; the WITH-IMAGE / WITH-IMAGES macros, or by WITH-IMAGE-POOL.  We deliberately
;;; do NOT register GC finalizers -- an image can pin a large foreign pixel
;;; buffer that the Lisp GC cannot see or account for, so relying on collection
;;; timing lets C memory grow unbounded.  A dropped, never-freed image simply
;;; leaks; enable SET-LEAK-CHECKING during development to have libvips report
;;; such leaks at SHUTDOWN.
;;; ---------------------------------------------------------------------------

(defvar *image-pool* nil
  "When non-NIL, a cons whose CAR accumulates every image created by
WRAP-IMAGE in the current dynamic extent, so WITH-IMAGE-POOL can free them all.
Bound only by WITH-IMAGE-POOL.")

(defstruct (image (:constructor %make-image (pointer &optional cleanup))
                  (:predicate imagep)
                  (:print-object print-image))
  (pointer (cffi:null-pointer))
  (live t)
  ;; Optional thunk run when the image is freed, e.g. to release a foreign
  ;; buffer that libvips references lazily (see IMAGE-FROM-OCTETS).
  (cleanup nil))

(defun print-image (image stream)
  (print-unreadable-object (image stream :type t :identity t)
    (if (image-live image)
        (ignore-errors
         (format stream "~dx~d ~a ~a"
                 (width image) (height image)
                 (bands image) (image-format image)))
        (format stream "<freed>"))))

(defun image-live-p (image)
  "Return T if IMAGE still owns a live libvips image."
  (and (image-live image) t))

(defun pointer-of (image)
  "Return the raw foreign pointer of IMAGE, signalling an error if it has
already been freed."
  (unless (image-live image)
    (error "Attempt to use a freed vips:image."))
  (image-pointer image))

(defun wrap-image (pointer &optional cleanup)
  "Wrap a freshly-returned VipsImage POINTER (which carries one reference the
caller now owns). Signals VIPS-ERROR if POINTER is NULL -- in which case
CLEANUP is run first so a caller-owned buffer is not leaked. If an image pool
is active (see WITH-IMAGE-POOL) the new image is registered with it.

The returned image must be released explicitly with UNREF, WITH-IMAGE,
WITH-IMAGES or WITH-IMAGE-POOL; it is never freed by the garbage collector."
  (when (cffi:null-pointer-p pointer)
    (when cleanup (funcall cleanup))
    (raise-vips-error))
  (let ((image (%make-image pointer cleanup)))
    (when *image-pool*
      (push image (car *image-pool*)))
    image))

(defun unref (image)
  "Explicitly drop IMAGE's reference to its VipsImage. Safe to call more than
once. After this, IMAGE is dead."
  (when (image-live image)
    (setf (image-live image) nil)
    (%g-object-unref (image-pointer image))
    (setf (image-pointer image) (cffi:null-pointer))
    (when (image-cleanup image)
      (funcall (image-cleanup image))
      (setf (image-cleanup image) nil)))
  (values))

(defmacro with-image ((var init-form) &body body)
  "Bind VAR to the image produced by INIT-FORM, run BODY, and UNREF VAR on
exit (normal or non-local)."
  `(let ((,var ,init-form))
     (unwind-protect (progn ,@body)
       (unref ,var))))

(defmacro with-images (bindings &body body)
  "Like WITH-IMAGE but for several bindings, freed in reverse order."
  (if (null bindings)
      `(progn ,@body)
      `(with-image ,(first bindings)
         (with-images ,(rest bindings) ,@body))))

(defmacro with-image-pool (&body body)
  "Evaluate BODY with an active image pool: every image created within its
dynamic extent (by loaders, creators or operations) is collected and UNREF'd
when BODY exits, normally or non-locally.

This is the deterministic way to manage an unknown number of temporary images
-- e.g. building a list of tiles in a loop -- without threading WITH-IMAGE
bindings through everything. Pools nest; each frees only its own images.

Note: the pool frees EVERY image made inside it, so do not return an image
created here and expect it to survive. To keep a result alive past the pool,
move it out with KEEP."
  (let ((pool (gensym "POOL")))
    `(let* ((,pool (cons nil nil))
            (*image-pool* ,pool))
       (unwind-protect (progn ,@body)
         (dolist (image (car ,pool))
           (unref image))))))

(defun keep (image)
  "Remove IMAGE from the innermost active image pool, if any, so it is NOT
freed when that WITH-IMAGE-POOL exits. Returns IMAGE. Outside a pool this is a
no-op. The caller then owns IMAGE and must UNREF it."
  (when *image-pool*
    (setf (car *image-pool*) (delete image (car *image-pool*))))
  image)

;;; ---------------------------------------------------------------------------
;;; Internal helpers for operations
;;; ---------------------------------------------------------------------------

(defmacro with-new-image ((out) &body body)
  "Bind OUT to a fresh `VipsImage **' cell, evaluate BODY (a foreign call that
returns an int status writing into OUT), and return the wrapped result image.
Signals VIPS-ERROR on non-zero status."
  (let ((status (gensym "STATUS")))
    `(cffi:with-foreign-object (,out :pointer)
       (let ((,status (progn ,@body)))
         (unless (zerop ,status)
           (raise-vips-error))
         (wrap-image (cffi:mem-ref ,out :pointer))))))

(defmacro with-stat-double ((out) &body body)
  "Like WITH-NEW-IMAGE but for operations returning a single double via OUT."
  (let ((status (gensym "STATUS")))
    `(cffi:with-foreign-object (,out :double)
       (let ((,status (progn ,@body)))
         (unless (zerop ,status)
           (raise-vips-error))
         (cffi:mem-ref ,out :double)))))

(defun to-double (x)
  (coerce x 'double-float))

;;; ---------------------------------------------------------------------------
;;; Loading & saving
;;; ---------------------------------------------------------------------------

(defun load-image (path)
  "Load the image at PATH (a pathname or string) and return an IMAGE."
  (ensure-init)
  (let ((namestring (namestring (pathname path))))
    (wrap-image
     (cffi:foreign-funcall-varargs "vips_image_new_from_file"
                                   (:string namestring)
                                   :pointer (cffi:null-pointer)
                                   :pointer))))

(defun save-image (image path)
  "Write IMAGE to PATH. The format is chosen from PATH's extension. Returns
PATH."
  (let ((namestring (namestring (pathname path))))
    (let ((status (cffi:foreign-funcall-varargs "vips_image_write_to_file"
                                                (:pointer (pointer-of image)
                                                 :string namestring)
                                                :pointer (cffi:null-pointer)
                                                :int)))
      (unless (zerop status)
        (raise-vips-error)))
    path))

(defun image-from-octets (octets &optional (option-string ""))
  "Decode an in-memory encoded image (e.g. the bytes of a PNG/JPEG file) held
in OCTETS (a vector of (unsigned-byte 8)) and return an IMAGE. OPTION-STRING
is passed to the libvips loader."
  (ensure-init)
  ;; libvips references the buffer lazily rather than copying it, so it must
  ;; outlive the image.  Allocate it with FOREIGN-ALLOC and free it via the
  ;; image's cleanup thunk rather than a stack-scoped WITH-FOREIGN-OBJECT.
  (let* ((len (length octets))
         (buffer (cffi:foreign-alloc :uint8 :count len)))
    (dotimes (i len)
      (setf (cffi:mem-aref buffer :uint8 i) (aref octets i)))
    (wrap-image
     (cffi:foreign-funcall-varargs "vips_image_new_from_buffer"
                                   (:pointer buffer
                                    :unsigned-long len
                                    :string option-string)
                                   :pointer (cffi:null-pointer)
                                   :pointer)
     (lambda () (cffi:foreign-free buffer)))))

(defun write-to-octets (image suffix)
  "Encode IMAGE into an in-memory buffer using SUFFIX (e.g. \".png\") to
choose the format, returning a fresh (unsigned-byte 8) vector."
  (cffi:with-foreign-objects ((buffer :pointer) (size :unsigned-long))
    (let ((status (cffi:foreign-funcall-varargs "vips_image_write_to_buffer"
                                                (:pointer (pointer-of image)
                                                 :string suffix
                                                 :pointer buffer
                                                 :pointer size)
                                                :pointer (cffi:null-pointer)
                                                :int)))
      (unless (zerop status)
        (raise-vips-error))
      (let* ((n (cffi:mem-ref size :unsigned-long))
             (data (cffi:mem-ref buffer :pointer))
             (result (make-array n :element-type '(unsigned-byte 8))))
        (dotimes (i n)
          (setf (aref result i) (cffi:mem-aref data :uint8 i)))
        (%g-free data)
        result))))

(defun image-from-pixels (octets width height bands &optional (format :uchar))
  "Build an IMAGE from raw, uncompressed pixel data in OCTETS. OCTETS must be
a vector of (unsigned-byte 8) of length WIDTH*HEIGHT*BANDS (for the default
:UCHAR format). The data is copied, so OCTETS need not outlive the image."
  (ensure-init)
  (let ((len (length octets)))
    (cffi:with-foreign-object (buffer :uint8 len)
      (dotimes (i len)
        (setf (cffi:mem-aref buffer :uint8 i) (aref octets i)))
      (wrap-image
       (cffi:foreign-funcall "vips_image_new_from_memory_copy"
                             :pointer buffer
                             :unsigned-long len
                             :int width
                             :int height
                             :int bands
                             band-format format
                             :pointer)))))

;;; ---------------------------------------------------------------------------
;;; Header / introspection
;;; ---------------------------------------------------------------------------

(cffi:defcfun ("vips_image_get_width" %image-width) :int (image :pointer))
(cffi:defcfun ("vips_image_get_height" %image-height) :int (image :pointer))
(cffi:defcfun ("vips_image_get_bands" %image-bands) :int (image :pointer))
(cffi:defcfun ("vips_image_get_format" %image-format) band-format (image :pointer))
(cffi:defcfun ("vips_image_get_interpretation" %image-interpretation)
    interpretation-enum
  (image :pointer))
(cffi:defcfun ("vips_image_get_filename" %image-filename) :string (image :pointer))

(defun width (image)
  "Width of IMAGE in pixels."
  (%image-width (pointer-of image)))

(defun height (image)
  "Height of IMAGE in pixels."
  (%image-height (pointer-of image)))

(defun bands (image)
  "Number of bands (channels) in IMAGE."
  (%image-bands (pointer-of image)))

(defun image-format (image)
  "Pixel storage format of IMAGE as a BAND-FORMAT keyword."
  (%image-format (pointer-of image)))

(defun interpretation (image)
  "Colour-space interpretation of IMAGE as an INTERPRETATION-ENUM keyword."
  (%image-interpretation (pointer-of image)))

(defun filename (image)
  "The filename IMAGE was loaded from, or NIL."
  (let ((name (%image-filename (pointer-of image))))
    (if (and name (plusp (length name))) name nil)))

(defun get-double (image field)
  "Return the double-valued metadata FIELD of IMAGE. Signals VIPS-ERROR if the
field is absent or of the wrong type."
  (cffi:with-foreign-object (out :double)
    (let ((status (cffi:foreign-funcall "vips_image_get_double"
                                        :pointer (pointer-of image)
                                        :string field
                                        :pointer out
                                        :int)))
      (unless (zerop status)
        (raise-vips-error))
      (cffi:mem-ref out :double))))

(defun get-int (image field)
  "Return the integer-valued metadata FIELD of IMAGE."
  (cffi:with-foreign-object (out :int)
    (let ((status (cffi:foreign-funcall "vips_image_get_int"
                                        :pointer (pointer-of image)
                                        :string field
                                        :pointer out
                                        :int)))
      (unless (zerop status)
        (raise-vips-error))
      (cffi:mem-ref out :int))))

(defun get-string (image field)
  "Return the string-valued metadata FIELD of IMAGE."
  (cffi:with-foreign-object (out :pointer)
    (let ((status (cffi:foreign-funcall "vips_image_get_as_string"
                                        :pointer (pointer-of image)
                                        :string field
                                        :pointer out
                                        :int)))
      (unless (zerop status)
        (raise-vips-error))
      (let* ((ptr (cffi:mem-ref out :pointer))
             (str (unless (cffi:null-pointer-p ptr)
                    (cffi:foreign-string-to-lisp ptr))))
        (unless (cffi:null-pointer-p ptr)
          (%g-free ptr))
        str))))

(defun getpoint (image x y)
  "Return the pixel at (X, Y) of IMAGE as a list of doubles, one per band."
  (cffi:with-foreign-objects ((vector :pointer) (n :int))
    (let ((status (cffi:foreign-funcall-varargs "vips_getpoint"
                                                (:pointer (pointer-of image)
                                                 :pointer vector
                                                 :pointer n
                                                 :int x
                                                 :int y)
                                                :pointer (cffi:null-pointer)
                                                :int)))
      (unless (zerop status)
        (raise-vips-error))
      (let* ((count (cffi:mem-ref n :int))
             (data (cffi:mem-ref vector :pointer))
             (result (loop for i below count
                           collect (cffi:mem-aref data :double i))))
        (%g-free data)
        result))))
