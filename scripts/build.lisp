;;;; scripts/build.lisp --- build a standalone `cl-vips' executable.
;;;;
;;;;   sbcl --script scripts/build.lisp        # writes ./cl-vips (next to the .asd)
;;;;
;;;; libvips is loaded lazily at run time (by vips:init), not baked into the
;;;; image, so the executable stays portable across the saved/restored image.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(push *root* asdf:*central-registry*)

(handler-bind ((warning #'muffle-warning))
  (ql:quickload :cl-vips/cli))

;; Write the executable into the project root, next to cl-vips.asd.
(let ((output (merge-pathnames "cl-vips" *root*)))
  (sb-ext:save-lisp-and-die
   output
   :toplevel (read-from-string "vips-cli:toplevel")
   :executable t
   :save-runtime-options t))
