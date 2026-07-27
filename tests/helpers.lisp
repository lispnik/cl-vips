;;;; tests/helpers.lisp --- Shared fixtures and helpers for the test suite

(in-package #:vips/test)

(defparameter *scratch-dir*
  (let ((dir #p"/private/tmp/claude-501/-Users-mkennedy-Projects-common-lisp-vips/d6e87b3b-ea9b-4433-8ea9-67e37db4ea32/scratchpad/vips-tests/"))
    (ensure-directories-exist dir)
    dir)
  "Directory for temporary files created by the tests.")

(defvar *temp-counter* 0)

(defun temp-path (extension)
  "Return a fresh, unique pathname in *SCRATCH-DIR* with EXTENSION (e.g.
\"png\")."
  (merge-pathnames
   (format nil "t~d-~d.~a"
           (incf *temp-counter*)
           (get-internal-real-time)
           extension)
   *scratch-dir*))

(defmacro with-temp-file ((var extension) &body body)
  "Bind VAR to a fresh temp pathname; delete the file (if created) afterwards."
  `(let ((,var (temp-path ,extension)))
     (unwind-protect (progn ,@body)
       (ignore-errors (when (probe-file ,var) (delete-file ,var))))))

(defun approx= (a b &optional (epsilon 1.0d-6))
  "True if A and B are within EPSILON."
  (< (abs (- a b)) epsilon))

;;; --- Pixel-data builders -------------------------------------------------

(defun solid-octets (width height bands value)
  "A width*height*bands (unsigned-byte 8) vector filled with VALUE."
  (make-array (* width height bands)
              :element-type '(unsigned-byte 8)
              :initial-element value))

(defun solid-image (width height &key (bands 1) (value 128))
  "A uniform image of VALUE built from raw memory (no file needed)."
  (vips:image-from-pixels (solid-octets width height bands value)
                          width height bands))

(defun ramp-octets (width height)
  "A single-band width*height ramp where pixel (x,y) = (x+y) mod 256."
  (let ((data (make-array (* width height) :element-type '(unsigned-byte 8))))
    (dotimes (y height)
      (dotimes (x width)
        (setf (aref data (+ (* y width) x)) (mod (+ x y) 256))))
    data))

(defun ramp-image (width height)
  "A single-band ramp image."
  (vips:image-from-pixels (ramp-octets width height) width height 1))

;;; A fixture that guarantees libvips is initialized for every test.
(def-fixture initialized ()
  (vips:init)
  (&body))
