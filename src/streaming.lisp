;;;; streaming.lisp --- Load/save through arbitrary Lisp binary streams
;;;;
;;;; libvips can read from a VipsSource and write to a VipsTarget. Here we back
;;;; a VipsSourceCustom / VipsTargetCustom with Lisp streams via read/seek/write
;;;; callbacks, so an image can be loaded from or saved to any binary stream
;;;; (file, network, in-memory) without a filename or a fully materialised
;;;; octet vector.

(in-package #:vips)

;;; ---------------------------------------------------------------------------
;;; Foreign layer
;;; ---------------------------------------------------------------------------

(cffi:defcfun ("vips_source_custom_new" %vips-source-custom-new) :pointer)
(cffi:defcfun ("vips_target_custom_new" %vips-target-custom-new) :pointer)
(cffi:defcfun ("vips_target_end" %vips-target-end) :int (target :pointer))

(cffi:defcfun ("g_signal_connect_data" %g-signal-connect-data) :unsigned-long
  (instance :pointer) (detailed-signal :string) (c-handler :pointer)
  (data :pointer) (destroy-data :pointer) (connect-flags :int))

(defun %connect (instance signal callback)
  (%g-signal-connect-data instance signal callback
                          (cffi:null-pointer) (cffi:null-pointer) 0))

;;; ---------------------------------------------------------------------------
;;; Stream registry: map a source/target pointer to its Lisp stream, so the
;;; C callbacks can find it. Keyed by pointer address.
;;; ---------------------------------------------------------------------------

(defvar *stream-registry* (make-hash-table)
  "Maps a VipsSourceCustom/VipsTargetCustom pointer address to its Lisp stream.")

(defun %register-stream (pointer stream)
  (setf (gethash (cffi:pointer-address pointer) *stream-registry*) stream))

(defun %unregister-stream (pointer)
  (remhash (cffi:pointer-address pointer) *stream-registry*))

(defun %stream-for (pointer)
  (gethash (cffi:pointer-address pointer) *stream-registry*))

(defparameter *stream-chunk* 65536
  "Maximum bytes moved per read/write callback invocation.")

;;; ---------------------------------------------------------------------------
;;; Callbacks
;;; ---------------------------------------------------------------------------

(cffi:defcallback %source-read :int64
    ((source :pointer) (buffer :pointer) (length :int64) (user :pointer))
  (declare (ignore user))
  (let ((stream (%stream-for source)))
    (if (null stream)
        -1
        (handler-case
            (let* ((want (min length *stream-chunk*))
                   (buf (make-array want :element-type '(unsigned-byte 8)))
                   (n (read-sequence buf stream)))
              (dotimes (i n)
                (setf (cffi:mem-aref buffer :uint8 i) (aref buf i)))
              n)                        ; 0 => EOF
          (error () -1)))))

(cffi:defcallback %source-seek :int64
    ((source :pointer) (offset :int64) (whence :int) (user :pointer))
  (declare (ignore user))
  (let ((stream (%stream-for source)))
    (handler-case
        (let ((target (ecase whence
                        (0 offset)                              ; SEEK_SET
                        (1 (+ (file-position stream) offset))   ; SEEK_CUR
                        (2 (+ (file-length stream) offset)))))  ; SEEK_END
          (if (file-position stream target) target -1))
      ;; A non-seekable stream (socket, pipe) => report unseekable.
      (error () -1))))

(cffi:defcallback %target-write :int64
    ((target :pointer) (buffer :pointer) (length :int64) (user :pointer))
  (declare (ignore user))
  (let ((stream (%stream-for target)))
    (if (null stream)
        -1
        (handler-case
            (let ((buf (make-array length :element-type '(unsigned-byte 8))))
              (dotimes (i length)
                (setf (aref buf i) (cffi:mem-aref buffer :uint8 i)))
              (write-sequence buf stream)
              length)
          (error () -1)))))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun load-image-from-stream (stream &optional (option-string ""))
  "Load an image by reading encoded bytes from STREAM, a binary input stream
whose element type is (unsigned-byte 8). The stream must stay open until the
returned image is freed (libvips reads pixels lazily). OPTION-STRING is passed
to the loader. Returns an IMAGE."
  (ensure-init)
  (let ((source (%vips-source-custom-new)))
    (when (cffi:null-pointer-p source)
      (raise-vips-error))
    (%register-stream source stream)
    (%connect source "read" (cffi:callback %source-read))
    (%connect source "seek" (cffi:callback %source-seek))
    (let ((image-ptr
            (cffi:foreign-funcall-varargs "vips_image_new_from_source"
                                          (:pointer source :string option-string)
                                          :pointer (cffi:null-pointer)
                                          :pointer)))
      (when (cffi:null-pointer-p image-ptr)
        (%unregister-stream source)
        (%g-object-unref source)
        (raise-vips-error))
      ;; The source (and its registry entry) must outlive the image.
      (wrap-image image-ptr
                  (lambda ()
                    (%unregister-stream source)
                    (%g-object-unref source))))))

(defun save-image-to-stream (image suffix stream)
  "Encode IMAGE (format chosen from SUFFIX, e.g. \".png\") and write the bytes
to STREAM, a binary output stream of element type (unsigned-byte 8). Everything
is written before returning."
  (ensure-init)
  (let ((target (%vips-target-custom-new)))
    (when (cffi:null-pointer-p target)
      (raise-vips-error))
    (%register-stream target stream)
    (unwind-protect
         (progn
           (%connect target "write" (cffi:callback %target-write))
           (let ((status
                   (cffi:foreign-funcall-varargs "vips_image_write_to_target"
                                                 (:pointer (pointer-of image)
                                                  :string suffix
                                                  :pointer target)
                                                 :pointer (cffi:null-pointer)
                                                 :int)))
             (unless (zerop status)
               (raise-vips-error))
             (%vips-target-end target)))
      (%unregister-stream target)
      (%g-object-unref target))
    (values)))
