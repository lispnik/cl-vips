;;;; ci/smoke.lisp --- portable load-and-run smoke test.
;;;;
;;;; Loads cl-vips/cli and exercises a representative slice of the library, so
;;;; CI can verify the binding loads and runs on implementations where building
;;;; the full FiveAM suite is slow (e.g. ECL). Exits non-zero on any failure.
;;;;
;;;;   sbcl --script ci/smoke.lisp
;;;;   ecl --shell   ci/smoke.lisp

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (uiop:getcwd) asdf:*central-registry*)
(handler-bind ((warning #'muffle-warning))
  (funcall (read-from-string "ql:quickload") :cl-vips/cli :silent t))

;; cl-vips is loaded now, so this package can :use it.
(defpackage :vips-smoke (:use :cl :vips))
(in-package :vips-smoke)

(defvar *failures* 0)

(defmacro check (name &body body)
  `(handler-case
       (progn ,@body (format t "~&ok   ~a~%" ,name))
     (error (e) (incf *failures*) (format t "~&FAIL ~a: ~a~%" ,name e))))

(init)
(format t "~&smoke: libvips ~a~%" (version-string))

(check "version"        (assert (stringp (version-string))))
(check "black + bands"  (with-image (i (black 16 16 :bands 3)) (assert (= 3 (bands i)))))
(check "gaussblur"      (with-image (i (black 16 16))
                          (with-image (b (gaussblur i 1.5)) (assert (= 16 (width b))))))
(check "engine invert"  (with-image (i (black 8 8))
                          (with-image (r (call-operation "invert" (list "in" i)))
                            (assert (= 8 (width r))))))
(check "embed + extend" (with-image (i (black 4 4 :bands 3))
                          (with-image (e (embed i 2 2 8 8 :extend :white))
                            (assert (equal '(255 255 255)
                                           (mapcar #'round (getpoint e 0 0)))))))
(check "extract-band"   (with-image (i (black 4 4 :bands 3))
                          (with-image (x (extract-band i 0 :n 2)) (assert (= 2 (bands x))))))
(check "draw (modify)"  (with-image (i (black 12 12 :bands 3))
                          (with-image (d (call-operation
                                          "draw_circle"
                                          (list "image" i "ink" '(255 0 0)
                                                "cx" 6 "cy" 6 "radius" 3 "fill" t)))
                            (assert (equal '(255 0 0)
                                           (mapcar #'round (getpoint d 6 6)))))))
(check "metadata"       (with-image (i (black 4 4))
                          (set-int i "k" 7) (assert (= 7 (get-int i "k")))))
(check "array io"       (with-image (i (black 4 4 :bands 3))
                          (assert (equal '(4 4 3) (array-dimensions (image-to-array i))))))
(check "introspection"  (assert (member "gaussblur" (list-operations) :test #'string=)))
(check "cli main"       (assert (= 0 (vips-cli:main (list "version")))))

(if (zerop *failures*)
    (progn (format t "~&SMOKE PASS~%") (uiop:quit 0))
    (progn (format t "~&SMOKE FAILED (~d)~%" *failures*) (uiop:quit 1)))
