;;;; scripts/run.lisp --- dev entry point: `sbcl --script scripts/run.lisp ARGS'

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

;; Register the repository (this file's grandparent directory) with ASDF.
(push (uiop:pathname-parent-directory-pathname
       (uiop:pathname-directory-pathname *load-truename*))
      asdf:*central-registry*)

(handler-bind ((warning #'muffle-warning))
  (ql:quickload :cl-vips/cli :silent t))

(sb-ext:exit :code (funcall (read-from-string "vips-cli:main")))
