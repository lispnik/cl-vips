;;;; operations.lisp --- Image creation, transforms, arithmetic and statistics
;;;;
;;;; Every libvips operation function below is C-variadic: after its fixed
;;;; arguments comes an optional list of name/value option pairs terminated by
;;;; a NULL.  These MUST be called through CFFI:FOREIGN-FUNCALL-VARARGS so the
;;;; fixed/variadic boundary is marked -- on some ABIs (notably Apple arm64)
;;;; the variadic tail is passed on the stack, and a plain FOREIGN-FUNCALL
;;;; would mis-pass the NULL terminator and option pairs.

(in-package #:vips)

;;; ---------------------------------------------------------------------------
;;; Creation
;;; ---------------------------------------------------------------------------

(defun black (width height &key (bands 1))
  "Create a new all-black image of WIDTH x HEIGHT with BANDS channels."
  (ensure-init)
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_black"
                                  (:pointer out :int width :int height)
                                  :string "bands" :int bands
                                  :pointer (cffi:null-pointer)
                                  :int)))

;;; ---------------------------------------------------------------------------
;;; Geometry / transforms
;;; ---------------------------------------------------------------------------

(defun resize (image scale)
  "Resize IMAGE by SCALE (a real; 0.5 halves each dimension). Returns a new
image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_resize"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   :double (to-double scale))
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun crop (image left top width height)
  "Extract the WIDTH x HEIGHT area of IMAGE whose top-left corner is at
(LEFT, TOP). Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_extract_area"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   :int left :int top
                                   :int width :int height)
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun embed (image x y width height &key (extend :black))
  "Embed IMAGE in a WIDTH x HEIGHT frame at offset (X, Y), filling new pixels
according to EXTEND (an EXTEND-ENUM keyword). Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_embed"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   :int x :int y
                                   :int width :int height)
                                  :string "extend"
                                  :int (cffi:foreign-enum-value 'extend-enum extend)
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun flip (image direction)
  "Flip IMAGE along DIRECTION (:HORIZONTAL or :VERTICAL). Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_flip"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   direction-enum direction)
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun rotate (image angle)
  "Rotate IMAGE by a fixed ANGLE (:D0, :D90, :D180 or :D270). Returns a new
image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_rot"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   angle-enum angle)
                                  :pointer (cffi:null-pointer)
                                  :int)))

;;; ---------------------------------------------------------------------------
;;; Pixel / colour
;;; ---------------------------------------------------------------------------

(defun invert (image)
  "Invert IMAGE (photographic negative). Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_invert"
                                  (:pointer (pointer-of image) :pointer out)
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun linear (image a b)
  "Compute A*IMAGE + B for scalars A and B (applied to every band). Returns a
new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_linear1"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   :double (to-double a)
                                   :double (to-double b))
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun gaussblur (image sigma)
  "Gaussian blur IMAGE with standard deviation SIGMA. Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_gaussblur"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   :double (to-double sigma))
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun colourspace (image space)
  "Convert IMAGE to the colour space SPACE (an INTERPRETATION-ENUM keyword,
e.g. :B-W or :SRGB). Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_colourspace"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   interpretation-enum space)
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun cast (image format)
  "Cast IMAGE's pixels to FORMAT (a BAND-FORMAT keyword). Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_cast"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   band-format format)
                                  :pointer (cffi:null-pointer)
                                  :int)))

;;; ---------------------------------------------------------------------------
;;; Bands
;;; ---------------------------------------------------------------------------

(defun extract-band (image band &key (n 1))
  "Extract N bands from IMAGE starting at index BAND. Returns a new image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_extract_band"
                                  (:pointer (pointer-of image)
                                   :pointer out
                                   :int band)
                                  :string "n" :int n
                                  :pointer (cffi:null-pointer)
                                  :int)))

(defun bandjoin (image1 image2)
  "Join the bands of IMAGE1 and IMAGE2 (IMAGE1's bands first). Returns a new
image."
  (with-new-image (out)
    (cffi:foreign-funcall-varargs "vips_bandjoin2"
                                  (:pointer (pointer-of image1)
                                   :pointer (pointer-of image2)
                                   :pointer out)
                                  :pointer (cffi:null-pointer)
                                  :int)))

;;; ---------------------------------------------------------------------------
;;; Arithmetic (two images)
;;; ---------------------------------------------------------------------------

(macrolet ((define-binop (name c-name doc)
             `(defun ,name (left right)
                ,doc
                (with-new-image (out)
                  (cffi:foreign-funcall-varargs ,c-name
                                                (:pointer (pointer-of left)
                                                 :pointer (pointer-of right)
                                                 :pointer out)
                                                :pointer (cffi:null-pointer)
                                                :int)))))
  (define-binop add "vips_add" "Add LEFT and RIGHT pixelwise. Returns a new image.")
  (define-binop subtract "vips_subtract"
    "Subtract RIGHT from LEFT pixelwise. Returns a new image.")
  (define-binop multiply "vips_multiply"
    "Multiply LEFT and RIGHT pixelwise. Returns a new image."))

;;; ---------------------------------------------------------------------------
;;; Statistics (single double result)
;;; ---------------------------------------------------------------------------

(macrolet ((define-stat (name c-name doc)
             `(defun ,name (image)
                ,doc
                (with-stat-double (out)
                  (cffi:foreign-funcall-varargs ,c-name
                                                (:pointer (pointer-of image)
                                                 :pointer out)
                                                :pointer (cffi:null-pointer)
                                                :int)))))
  (define-stat avg "vips_avg"
    "Return the mean pixel value of IMAGE across all bands, as a double.")
  (define-stat image-min "vips_min"
    "Return the minimum pixel value of IMAGE, as a double.")
  (define-stat image-max "vips_max"
    "Return the maximum pixel value of IMAGE, as a double.")
  (define-stat deviate "vips_deviate"
    "Return the standard deviation of IMAGE's pixels, as a double."))
