;;;; tests/package.lisp --- Test package for cl-vips

(defpackage #:vips/test
  (:use #:cl #:fiveam)
  (:export #:all-tests #:run-tests))

(in-package #:vips/test)

(def-suite all-tests
  :description "All cl-vips tests.")

(defun run-tests ()
  "Run the whole cl-vips test suite, returning T on complete success."
  (vips:init)
  (let ((results (run! 'all-tests)))
    results))
