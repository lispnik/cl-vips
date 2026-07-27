;;;; cl-vips.asd --- ASDF system definition for the libvips CFFI binding

(asdf:defsystem #:cl-vips
  :description "CFFI bindings to libvips, a fast image-processing library."
  :author "burnsidemk@gmail.com"
  :license "LGPL-2.1-or-later"
  :version "0.1.0"
  :depends-on (#:cffi)
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
                             (:file "generic"))))
  :in-order-to ((asdf:test-op (asdf:test-op #:cl-vips/test))))

(asdf:defsystem #:cl-vips/cli
  :description "Command-line driver for cl-vips."
  :author "burnsidemk@gmail.com"
  :license "LGPL-2.1-or-later"
  :depends-on (#:cl-vips)
  :components ((:module "cli"
                :pathname "src"
                :components ((:file "cli")))))

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
