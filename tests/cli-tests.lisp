;;;; tests/cli-tests.lisp --- The command-line driver (in-process)

(in-package #:vips/test)

(def-suite cli-suite :description "Command-line driver."
  :in all-tests)
(in-suite cli-suite)

(defmacro capturing ((code-var) &body body)
  "Run BODY (which should call VIPS-CLI:MAIN) with *STANDARD-OUTPUT* captured;
bind CODE-VAR to the returned exit code and return (values output code)."
  (let ((out (gensym)))
    `(let* (,code-var
            (,out (with-output-to-string (*standard-output*)
                    (setf ,code-var (progn ,@body)))))
       (values ,out ,code-var))))

(defun make-png (path &key (width 32) (height 32) (value 90))
  (vips:with-image (img (solid-image width height :bands 3 :value value))
    (vips:save-image img path))
  path)

(test cli-version
  "`version' succeeds and mentions libvips."
  (with-fixture initialized ()
    (multiple-value-bind (out code) (capturing (c) (vips-cli:main '("version")))
      (is (= 0 code))
      (is (search "libvips" out)))))

(test cli-help-when-empty
  "No arguments prints usage and succeeds."
  (with-fixture initialized ()
    (multiple-value-bind (out code) (capturing (c) (vips-cli:main '()))
      (is (= 0 code))
      (is (search "Usage" out)))))

(test cli-info
  "`info' reports an image's header fields."
  (with-fixture initialized ()
    (with-temp-file (path "png")
      (make-png path :width 40 :height 24)
      (multiple-value-bind (out code)
          (capturing (c) (vips-cli:main (list "info" (namestring path))))
        (is (= 0 code))
        (is (search "width          : 40" out))
        (is (search "height         : 24" out))))))

(test cli-list-and-groups
  "`list' and `groups' enumerate operations and families."
  (with-fixture initialized ()
    (multiple-value-bind (out code) (capturing (c) (vips-cli:main '("list")))
      (is (= 0 code))
      (is (search "gaussblur" out)))
    (multiple-value-bind (out code)
        (capturing (c) (vips-cli:main '("list" "arithmetic")))
      (is (= 0 code))
      (is (search "invert" out)))
    (multiple-value-bind (out code) (capturing (c) (vips-cli:main '("groups")))
      (is (= 0 code))
      (is (search "arithmetic" out)))))

(test cli-describe
  "`describe' shows an operation's arguments."
  (with-fixture initialized ()
    (multiple-value-bind (out code)
        (capturing (c) (vips-cli:main '("describe" "gaussblur")))
      (is (= 0 code))
      (is (search "sigma" out))
      (is (search "required" out)))))

(test cli-run-operation-shortcut
  "The nickname shortcut runs an operation and writes the output image."
  (with-fixture initialized ()
    (with-temp-file (in "png")
      (with-temp-file (out "png")
        (make-png in :width 32 :height 32)
        (multiple-value-bind (text code)
            (capturing (c)
              (vips-cli:main (list "gaussblur" (namestring in)
                                   (namestring out) "sigma=2")))
          (declare (ignore text))
          (is (= 0 code))
          (is (probe-file out))
          (vips:with-image (result (vips:load-image out))
            (is (= 32 (vips:width result)))))))))

(test cli-run-with-scale-option
  "resize with a parsed numeric option changes the dimensions."
  (with-fixture initialized ()
    (with-temp-file (in "png")
      (with-temp-file (out "png")
        (make-png in :width 40 :height 20)
        (let ((code (with-output-to-string (*standard-output*)
                      (vips-cli:main (list "resize" (namestring in)
                                           (namestring out) "scale=0.5")))))
          (declare (ignore code))
          (vips:with-image (result (vips:load-image out))
            (is (= 20 (vips:width result)))
            (is (= 10 (vips:height result)))))))))

(test cli-scalar-output
  "An operation with a scalar result prints a number and succeeds."
  (with-fixture initialized ()
    (with-temp-file (in "png")
      (make-png in :value 77)
      (multiple-value-bind (out code)
          (capturing (c) (vips-cli:main (list "avg" (namestring in))))
        (is (= 0 code))
        (is (plusp (length (string-trim '(#\Space #\Newline) out))))))))

(test cli-unknown-operation-exit-code
  "An unknown operation returns a non-zero exit code."
  (with-fixture initialized ()
    (with-temp-file (in "png")
      (make-png in)
      ;; error text goes to *error-output*; we only check the code
      (let ((code (let ((*error-output* (make-string-output-stream)))
                    (vips-cli:main (list "no_such_op" (namestring in)
                                         "/tmp/ignored.png")))))
        (is (= 1 code))))))

(test cli-value-parsing
  "Booleans, integers, floats and comma-lists parse as expected."
  (is (eq t (vips-cli::parse-value "true")))
  (is (eq nil (vips-cli::parse-value "false")))
  (is (eql 5 (vips-cli::parse-value "5")))
  (is (approx= 0.5d0 (vips-cli::parse-value "0.5")))
  (is (equal '(1 2 3) (vips-cli::parse-value "1,2,3")))
  (is (string= "horizontal" (vips-cli::parse-value "horizontal"))))

;;; --- CLI: draw ops, creators, image-file options -------------------------

(test cli-draw-operation
  "The CLI runs an in-place draw op (infile -> the op's image input)."
  (with-fixture initialized ()
    (with-temp-file (in "png")
      (with-temp-file (out "png")
        (make-png in :width 20 :height 20 :value 0)
        (let ((code (with-output-to-string (*standard-output*)
                      (vips-cli:main (list "draw_circle" (namestring in)
                                           (namestring out)
                                           "ink=255,0,0" "cx=10" "cy=10"
                                           "radius=5" "fill=true")))))
          (declare (ignore code))
          (is (probe-file out))
          (vips:with-image (drawn (vips:load-image out))
            (is (equal '(255 0 0) (mapcar #'round (vips:getpoint drawn 10 10))))))))))

(test cli-creator-operation
  "The CLI runs a creator (no image input; first positional is the output)."
  (with-fixture initialized ()
    (with-temp-file (out "png")
      (multiple-value-bind (text code)
          (capturing (c) (vips-cli:main (list "black" (namestring out)
                                              "width=16" "height=12" "bands=3")))
        (declare (ignore text))
        (is (= 0 code))
        (is (probe-file out))
        (vips:with-image (img (vips:load-image out))
          (is (= 16 (vips:width img)))
          (is (= 12 (vips:height img))))))))

(test cli-image-file-option
  "An @FILE option loads a second image (composite2 overlay=@file)."
  (with-fixture initialized ()
    (with-temp-file (base "png")
      (with-temp-file (over "png")
        (with-temp-file (out "png")
          (make-png base :width 16 :height 16 :value 100)
          (make-png over :width 16 :height 16 :value 40)
          (let ((code (with-output-to-string (*standard-output*)
                        (vips-cli:main (list "composite2" (namestring base)
                                             (namestring out)
                                             (format nil "overlay=@~a" (namestring over))
                                             "mode=over")))))
            (declare (ignore code))
            (is (probe-file out))
            (vips:with-image (img (vips:load-image out))
              (is (= 16 (vips:width img))))))))))
