;;;; cl-vips.asd --- ASDF system definition for the libvips CFFI binding

(asdf:defsystem #:cl-vips
  :description "CFFI bindings to libvips, a fast image-processing library."
  :author "burnsidemk@gmail.com"
  :license "LGPL-2.1-or-later"
  :version "0.1.0"
  :depends-on (#:cffi #:bordeaux-threads)
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "library")
                             (:file "conditions")
                             (:file "enums")
                             (:file "core")
                             (:file "image")
                             (:file "operations")
                             (:file "generic")
                             (:file "streaming"))))
  :in-order-to ((asdf:test-op (asdf:test-op #:cl-vips/test))))

(asdf:defsystem #:cl-vips/cli
  :description "Command-line driver for cl-vips."
  :author "burnsidemk@gmail.com"
  :license "LGPL-2.1-or-later"
  :depends-on (#:cl-vips)
  :components ((:module "cli"
                :pathname "src"
                :components ((:file "cli")))))

;;; Build the standalone `cl-vips' executable with ASDF:
;;;
;;;   sbcl --eval '(require :asdf)' --eval '(asdf:make :cl-vips/executable)'
;;;
;;; asdf:make runs the :build-operation (program-op), which dumps an
;;; executable named by :build-pathname (./cl-vips, next to this .asd) that
;;; starts at :entry-point.  libvips is loaded lazily at run time by vips:init,
;;; not baked into the image.
(asdf:defsystem #:cl-vips/executable
  :description "Standalone executable build of the cl-vips CLI."
  :author "burnsidemk@gmail.com"
  :license "LGPL-2.1-or-later"
  :depends-on (#:cl-vips/cli)
  :build-operation "program-op"
  :build-pathname "cl-vips"
  :entry-point "vips-cli:toplevel")

(asdf:defsystem #:cl-vips/test
  :description "Test suite for cl-vips."
  :author "burnsidemk@gmail.com"
  :license "LGPL-2.1-or-later"
  :depends-on (#:cl-vips #:cl-vips/cli #:fiveam)
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "helpers")
                             (:file "core-tests")
                             (:file "image-tests")
                             (:file "operations-tests")
                             (:file "generic-tests")
                             (:file "cli-tests")
                             (:file "error-tests"))))
  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :all-tests :vips/test))))
