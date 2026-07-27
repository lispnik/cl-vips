;;;; tests/generic-tests.lisp --- The generic VipsOperation engine (Phase 1)

(in-package #:vips/test)

(def-suite generic-suite :description "Generic operation engine."
  :in all-tests)
(in-suite generic-suite)

(defun px (image x y)
  "First-band value of the pixel at (X, Y)."
  (first (vips:getpoint image x y)))

;;; --- Equivalence with hand-bound operations ------------------------------

(test engine-invert-matches-hand-bound
  "call-operation \"invert\" reproduces the hand-bound INVERT pixelwise."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 8 8))
      (vips:with-images ((a (vips:invert img))
                         (b (vips:call-operation "invert" (list "in" img))))
        (is (approx= (px a 3 4) (px b 3 4)))
        (is (approx= (px a 0 0) (px b 0 0)))))))

(test engine-flip-enum-arg
  "An enum argument (:horizontal) passed through the engine matches FLIP."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 6 6))
      (vips:with-images ((a (vips:flip img :horizontal))
                         (b (vips:call-operation
                             "flip" (list "in" img "direction" :horizontal))))
        (is (approx= (px a 0 0) (px b 0 0)))
        (is (approx= (px a 5 5) (px b 5 5)))))))

(test engine-double-arg-matches-gaussblur
  "A double argument (sigma) through the engine matches GAUSSBLUR."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 32 32 :value 70))
      (vips:with-images ((a (vips:gaussblur img 2.0))
                         (b (vips:call-operation
                             "gaussblur" (list "in" img "sigma" 2.0d0))))
        (is (= (vips:width a) (vips:width b)))
        (is (approx= (vips:avg a) (vips:avg b) 1.0d-3))))))

;;; --- Scalar (non-image) outputs ------------------------------------------

(test engine-returns-scalar-double
  "An operation whose output is a double (avg) is returned as a number."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 8 8 :value 55))
      (let ((result (vips:call-operation "avg" (list "in" img))))
        (is (typep result 'double-float))
        (is (approx= 55.0d0 result))))))

;;; --- Object outputs are wrapped and owned --------------------------------

(test engine-image-output-is-live-image
  "An image output is returned as a live vips:image the caller owns."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 10 10 :value 20))
      (vips:with-image (out (vips:call-operation "invert" (list "in" img)))
        (is-true (vips:imagep out))
        (is-true (vips:image-live-p out))
        (is (= 10 (vips:width out)))
        (is (approx= 235.0d0 (px out 0 0)))))))

;;; --- Operations available only via the engine ----------------------------

(test engine-image-abs
  "IMAGE-ABS (defined via the engine) takes the absolute value."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 6 6))
      ;; cast to float so negatives are representable, negate, then abs
      (vips:with-images ((f (vips:cast img :float))
                         (neg (vips:linear f -1 0))
                         (a (vips:image-abs neg)))
        ;; pixel (1,2) of ramp = 3  ->  -3  ->  abs 3
        (is (approx= 3.0d0 (px a 1 2)))
        ;; pixel (5,5) of ramp = 10 -> -10 -> abs 10
        (is (approx= 10.0d0 (px a 5 5)))))))

(test engine-sign
  "SIGN maps values to -1/0/1."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 4 4))
      (vips:with-images ((f (vips:cast img :float))
                         (shifted (vips:linear f 1 -3)) ; range now -3..3
                         (s (vips:sign shifted)))
        (is (approx= -1.0d0 (px s 0 0)))   ; (x+y)=0 -> -3 -> -1
        (is (approx=  1.0d0 (px s 3 3))))))) ; (x+y)=6 -> 3 -> 1

(test engine-gamma-runs
  "GAMMA (engine, with a keyword option) returns a same-sized image."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 8 8 :bands 3 :value 100))
      (vips:with-image (g (vips:gamma img :exponent 2.2))
        (is (= 8 (vips:width g)))
        (is (= 3 (vips:bands g)))))))

;;; --- Phase 2: array arguments --------------------------------------------

(test engine-array-double-input
  "A VipsArrayDouble input (per-band a/b for \"linear\") is boxed correctly."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 2 2 :bands 3 :value 100))
      ;; out = a*in + b, per band: (2*100+0, 1*100+10, 0*100+5)
      (vips:with-image (out (vips:call-operation
                             "linear"
                             (list "in" img
                                   "a" '(2.0 1.0 0.0)
                                   "b" '(0.0 10.0 5.0))))
        (let ((px (vips:getpoint out 0 0)))
          (is (approx= 200.0d0 (first px)))
          (is (approx= 110.0d0 (second px)))
          (is (approx=   5.0d0 (third px))))))))

(test engine-scalar-promotes-to-array
  "A lone number is promoted to a one-element array for an array argument."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :bands 1 :value 50))
      ;; embed into a bigger frame, filling with the scalar background 200
      (vips:with-image (out (vips:call-operation
                             "embed"
                             (list "in" img "x" 1 "y" 1 "width" 8 "height" 8
                                   "extend" :background "background" 200)))
        (is (approx= 200.0d0 (px out 0 0)))   ; padding
        (is (approx=  50.0d0 (px out 1 1))))))) ; the embedded image

(test engine-array-double-output
  "A VipsArrayDouble output (\"getpoint\" -> out_array) is unboxed to a list."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 8 8))
      (let ((vec (vips:call-operation "getpoint"
                                      (list "in" img "x" 1 "y" 2)
                                      :output "out_array")))
        (is (listp vec))
        (is (= 1 (length vec)))
        ;; ramp pixel (1,2) = 1+2 = 3, and equals the hand getpoint
        (is (approx= 3.0d0 (first vec)))
        (is (approx= (first (vips:getpoint img 1 2)) (first vec)))))))

(test engine-array-int-input
  "A VipsArrayInt input (affine's \"oarea\") is boxed correctly."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 8 8 :value 50))
      ;; oarea = (left top width height) forces the output rectangle
      (vips:with-image (out (vips:call-operation
                             "affine"
                             (list "in" img
                                   "matrix" '(1.0 0.0 0.0 1.0)
                                   "oarea" '(0 0 5 3))))
        (is (= 5 (vips:width out)))
        (is (= 3 (vips:height out)))))))

(test affine-wrapper-identity
  "The AFFINE wrapper with an identity matrix preserves the image."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 6 6))
      (vips:with-image (out (vips:affine img '(1.0 0.0 0.0 1.0)))
        (is (= 6 (vips:width out)))
        (is (= 6 (vips:height out)))
        (is (approx= (px img 2 3) (px out 2 3)))))))

;;; --- Phase 3: image arrays and blobs -------------------------------------

(test engine-array-image-input
  "A VipsArrayImage input (\"arrayjoin\") is boxed from a list of images."
  (with-fixture initialized ()
    (vips:with-images ((a (solid-image 4 4 :value 10))
                       (b (solid-image 4 4 :value 20)))
      (vips:with-image (row (vips:call-operation
                             "arrayjoin" (list "in" (list a b) "across" 2)))
        (is (= 8 (vips:width row)))          ; two 4-wide images side by side
        (is (= 4 (vips:height row)))
        (is (approx= 10.0d0 (px row 0 0)))   ; left image
        (is (approx= 20.0d0 (px row 4 0))))))) ; right image

(test arrayjoin-refcounts-survive-input-free
  "The joined image stays valid after its inputs are freed -- the array took
its own references."
  (with-fixture initialized ()
    (let ((a (solid-image 4 4 :value 10))
          (b (solid-image 4 4 :value 20)))
      (vips:with-image (row (vips:arrayjoin (list a b) :across 2))
        (vips:unref a)
        (vips:unref b)
        ;; still readable: no use-after-free, no double-free
        (is (= 8 (vips:width row)))
        (is (approx= 10.0d0 (px row 0 0)))
        (is (approx= 20.0d0 (px row 4 0)))))))

(test engine-blob-input
  "A VipsBlob input (\"pngload_buffer\") is boxed from encoded bytes."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 8 8 :bands 3 :value 60))
      (let ((png (vips:write-to-octets img ".png")))
        (vips:with-image (decoded (vips:call-operation
                                   "pngload_buffer" (list "buffer" png)))
          (is (= 8 (vips:width decoded)))
          (is (= 8 (vips:height decoded)))
          (is (approx= 60.0d0 (px decoded 0 0))))))))

(test engine-blob-output
  "A VipsBlob output (\"profile_load\" -> profile) is unboxed to a byte vector."
  (with-fixture initialized ()
    (let ((profile (vips:call-operation "profile_load"
                                        (list "name" "srgb")
                                        :output "profile")))
      (is (typep profile '(vector (unsigned-byte 8))))
      (is (plusp (length profile)))
      ;; an ICC profile carries the "acsp" signature at byte offset 36
      (is (>= (length profile) 40))
      (is (equal '(#x61 #x63 #x73 #x70)         ; #\a #\c #\s #\p
                 (list (aref profile 36) (aref profile 37)
                       (aref profile 38) (aref profile 39)))))))

;;; --- Phase 4: introspection, multi-output, auto-wrappers -----------------

;; An auto-generated wrapper, defined at load time from introspection.
(vips:defvips test-scale "scale")

(test introspection-required-inputs
  "operation-required-inputs lists an operation's required inputs in order."
  (with-fixture initialized ()
    (is (equal '("in" "sigma") (vips:operation-required-inputs "gaussblur")))
    (is (equal '("in") (vips:operation-required-inputs "invert")))))

(test introspection-outputs
  "operation-outputs includes the primary and secondary outputs."
  (with-fixture initialized ()
    (let ((outs (vips:operation-outputs "min")))
      (is (member "out" outs :test #'string=))
      (is (member "x" outs :test #'string=))
      (is (member "y" outs :test #'string=)))))

(test introspection-argument-types
  "operation-arguments reports the GValue kind of each argument."
  (with-fixture initialized ()
    (let ((args (vips:operation-arguments "flip")))
      (flet ((typ (name)
               (getf (find name args :key (lambda (a) (getf a :name))
                                    :test #'string=)
                     :type)))
        (is (eq :object (typ "in")))
        (is (eq :object (typ "out")))
        (is (eq :enum (typ "direction")))))))

(test engine-multiple-outputs
  "call-operation with :outputs returns several values at once."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 4 4)) ; min value 0 lives at (0,0)
      (multiple-value-bind (value x y)
          (vips:call-operation "min" (list "in" img) :outputs '("out" "x" "y"))
        (is (approx= 0.0d0 value))
        (is (= 0 x))
        (is (= 0 y))))))

(test defvips-auto-wrapper
  "A defvips-generated wrapper introspects its required input and runs."
  (with-fixture initialized ()
    (is (fboundp 'test-scale))
    (vips:with-image (img (ramp-image 4 4))
      (vips:with-image (scaled (test-scale img)) ; scale stretches to 0..255
        (is (= 4 (vips:width scaled)))
        (is (approx= 255.0d0 (vips:image-max scaled)))))))

(test make-operation-caller-arity-check
  "A generated caller signals if a required input is missing."
  (with-fixture initialized ()
    (let ((blur (vips:make-operation-caller "gaussblur"))) ; needs in + sigma
      (signals vips:vips-error (funcall blur)))))

(test describe-operation-produces-text
  "describe-operation writes a non-empty summary."
  (with-fixture initialized ()
    (let ((text (with-output-to-string (s)
                  (vips:describe-operation "invert" s))))
      (is (plusp (length text)))
      (is (search "invert" text)))))

;;; --- Phase 4b: enumeration and bulk generation ---------------------------

(test enumerate-operations
  "list-operations returns a large set including known nicknames."
  (with-fixture initialized ()
    (let ((ops (vips:list-operations)))
      (is (> (length ops) 100))
      (is (member "gaussblur" ops :test #'string=))
      (is (member "invert" ops :test #'string=))
      (is (member "add" ops :test #'string=)))))

(test enumerate-groups
  "operation-groups includes the standard families."
  (with-fixture initialized ()
    (let ((groups (vips:operation-groups)))
      (dolist (g '("arithmetic" "conversion" "colour" "resample"))
        (is (member g groups :test #'string=)
            "group ~a should be present" g)))))

(test operations-in-a-group
  "operations-in-group agrees with membership expectations."
  (with-fixture initialized ()
    (let ((arith (vips:operations-in-group "arithmetic")))
      (is (member "add" arith :test #'string=))
      (is (member "invert" arith :test #'string=))
      ;; resize is a resample op, not arithmetic
      (is (not (member "resize" arith :test #'string=))))))

(test defvips-all-generates-group
  "defvips-all bulk-defines callable wrappers for a whole group."
  (with-fixture initialized ()
    (let* ((pkg (or (find-package :vips/test/gen)
                    (make-package :vips/test/gen :use '())))
           (defined (vips:defvips-all :group "arithmetic"
                                      :package pkg :prefix "op-")))
      (is (> (length defined) 5))
      ;; a generated wrapper is fbound and actually works
      (let ((inv (find-symbol "OP-INVERT" pkg)))
        (is (and inv (fboundp inv)))
        (vips:with-image (img (solid-image 4 4 :value 40))
          (vips:with-image (out (funcall inv img))
            (is (approx= 215.0d0 (px out 0 0)))))))))

;;; --- Error handling ------------------------------------------------------

(test engine-unknown-operation-signals
  "An unknown operation nickname signals VIPS-ERROR."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4))
      (signals vips:vips-error
        (vips:call-operation "no_such_operation_xyzzy" (list "in" img))))))

(test engine-unknown-argument-signals
  "Setting an argument the operation does not have signals VIPS-ERROR."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4))
      (signals vips:vips-error
        (vips:call-operation "invert" (list "in" img "not-an-arg" 5))))))

(test engine-missing-required-argument-signals
  "Building an operation without its required input signals VIPS-ERROR."
  (with-fixture initialized ()
    (signals vips:vips-error
      (vips:call-operation "invert" '()))))

;;; --- In-place (MODIFY) operations ----------------------------------------

(test engine-modify-draw-operation
  "An in-place MODIFY op (draw_circle) returns the mutated image and leaves the
input image untouched (the engine draws on a private memory copy)."
  (with-fixture initialized ()
    (vips:with-image (img (vips:black 20 20 :bands 3))
      (vips:with-image (drawn (vips:call-operation
                               "draw_circle"
                               (list "image" img "ink" '(255 128 0)
                                     "cx" 10 "cy" 10 "radius" 6 "fill" t)))
        (is (vips:imagep drawn))
        ;; centre was painted with the ink colour
        (is (equal '(255 128 0) (mapcar #'round (vips:getpoint drawn 10 10))))
        ;; a corner is still background
        (is (equal '(0 0 0) (mapcar #'round (vips:getpoint drawn 0 0))))
        ;; and the ORIGINAL image is unchanged
        (is (equal '(0 0 0) (mapcar #'round (vips:getpoint img 10 10))))))))
