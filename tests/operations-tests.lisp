;;;; tests/operations-tests.lisp --- Transforms, arithmetic and statistics

(in-package #:vips/test)

(def-suite operations-suite :description "Image operations."
  :in all-tests)
(in-suite operations-suite)

;;; --- Creation ------------------------------------------------------------

(test black-creates-zeroed-image
  "BLACK makes an image of the requested size, all zero."
  (with-fixture initialized ()
    (vips:with-image (img (vips:black 5 6 :bands 3))
      (is (= 5 (vips:width img)))
      (is (= 6 (vips:height img)))
      (is (= 3 (vips:bands img)))
      (is (approx= 0.0d0 (vips:avg img))))))

;;; --- Geometry ------------------------------------------------------------

(test resize-scales-dimensions
  "RESIZE by 0.5 halves each dimension."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 20 10 :value 100))
      (vips:with-image (small (vips:resize img 0.5))
        (is (= 10 (vips:width small)))
        (is (= 5 (vips:height small)))
        ;; a uniform image stays uniform under resize
        (is (approx= 100.0d0 (vips:avg small) 1.0d0))))))

(test crop-extracts-area
  "CROP returns exactly the requested rectangle from the right place."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 10 10))
      (vips:with-image (c (vips:crop img 2 3 4 4))
        (is (= 4 (vips:width c)))
        (is (= 4 (vips:height c)))
        ;; pixel (0,0) of the crop == pixel (2,3) of the source == 2+3
        (is (approx= 5.0d0 (first (vips:getpoint c 0 0))))))))

(test embed-enlarges-frame
  "EMBED places the image in a larger black frame."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :value 255))
      (vips:with-image (e (vips:embed img 3 3 10 10 :extend :black))
        (is (= 10 (vips:width e)))
        (is (= 10 (vips:height e)))
        ;; corner is padding => black; centre is the image => 255
        (is (approx= 0.0d0 (first (vips:getpoint e 0 0))))
        (is (approx= 255.0d0 (first (vips:getpoint e 4 4))))))))

(test flip-horizontal
  "FLIP :HORIZONTAL mirrors columns."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 6 6))
      (let ((orig (first (vips:getpoint img 0 0))))       ; x=0 => 0
        (vips:with-image (f (vips:flip img :horizontal))
          ;; after horizontal flip, old rightmost column is now at x=0
          (is (approx= (+ 5.0d0 orig) (first (vips:getpoint f 0 0)))))))))

(test rotate-swaps-dimensions
  "ROTATE :D90 swaps width and height."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 8 4))
      (vips:with-image (r (vips:rotate img :d90))
        (is (= 4 (vips:width r)))
        (is (= 8 (vips:height r)))))))

;;; --- Pixel / colour ------------------------------------------------------

(test invert-uchar
  "INVERT maps v -> 255-v for uchar images."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :value 40))
      (vips:with-image (inv (vips:invert img))
        (is (approx= 215.0d0 (first (vips:getpoint inv 0 0))))))))

(test linear-affine
  "LINEAR computes a*x + b."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :value 10))
      (vips:with-image (out (vips:linear img 2.0 5.0))
        (is (approx= 25.0d0 (first (vips:getpoint out 0 0))))))))

(test gaussblur-preserves-mean
  "Blurring a uniform image leaves its mean unchanged and its size intact."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 32 32 :value 90))
      (vips:with-image (b (vips:gaussblur img 2.0))
        (is (= 32 (vips:width b)))
        (is (approx= 90.0d0 (vips:avg b) 1.0d0))))))

(test colourspace-to-bw
  "Converting an RGB image to :B-W yields a single band."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :bands 3 :value 120))
      (vips:with-image (bw (vips:colourspace img :b-w))
        (is (= 1 (vips:bands bw)))))))

(test cast-changes-format
  "CAST changes the pixel storage format."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :value 100))
      (vips:with-image (u (vips:cast img :ushort))
        (is (eq :ushort (vips:image-format u)))))))

;;; --- Bands ---------------------------------------------------------------

(test extract-band-single
  "EXTRACT-BAND pulls out one channel."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :bands 3 :value 77))
      (vips:with-image (b (vips:extract-band img 1))
        (is (= 1 (vips:bands b)))
        (is (approx= 77.0d0 (first (vips:getpoint b 0 0))))))))

(test bandjoin-combines
  "BANDJOIN concatenates the bands of two images."
  (with-fixture initialized ()
    (vips:with-images ((a (solid-image 4 4 :bands 1 :value 10))
                       (b (solid-image 4 4 :bands 2 :value 20)))
      (vips:with-image (j (vips:bandjoin a b))
        (is (= 3 (vips:bands j)))
        (is (equal (mapcar #'round (vips:getpoint j 0 0))
                   '(10 20 20)))))))

;;; --- Arithmetic ----------------------------------------------------------

(test add-images
  "ADD sums two images pixelwise."
  (with-fixture initialized ()
    (vips:with-images ((a (solid-image 4 4 :value 30))
                       (b (solid-image 4 4 :value 45)))
      (vips:with-image (s (vips:add a b))
        (is (approx= 75.0d0 (first (vips:getpoint s 0 0))))))))

(test subtract-images
  "SUBTRACT differences two images pixelwise."
  (with-fixture initialized ()
    (vips:with-images ((a (solid-image 4 4 :value 90))
                       (b (solid-image 4 4 :value 25)))
      (vips:with-image (d (vips:subtract a b))
        (is (approx= 65.0d0 (first (vips:getpoint d 0 0))))))))

(test multiply-images
  "MULTIPLY multiplies two images pixelwise (result promotes format)."
  (with-fixture initialized ()
    (vips:with-images ((a (solid-image 4 4 :value 3))
                       (b (solid-image 4 4 :value 4)))
      (vips:with-image (m (vips:multiply a b))
        (is (approx= 12.0d0 (first (vips:getpoint m 0 0))))))))

;;; --- Statistics ----------------------------------------------------------

(test statistics-on-ramp
  "AVG / MIN / MAX / DEVIATE report the expected numbers for a ramp."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 4 4))
      ;; values are (x+y) for x,y in 0..3 => min 0, max 6
      (is (approx= 0.0d0 (vips:image-min img)))
      (is (approx= 6.0d0 (vips:image-max img)))
      (is (< 0.0d0 (vips:avg img) 6.0d0))
      (is (< 0.0d0 (vips:deviate img))))))

(test statistics-on-uniform
  "A uniform image has zero deviation and equal min/max/avg."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 8 8 :value 60))
      (is (approx= 60.0d0 (vips:avg img)))
      (is (approx= 60.0d0 (vips:image-min img)))
      (is (approx= 60.0d0 (vips:image-max img)))
      (is (approx= 0.0d0 (vips:deviate img))))))

;;; --- Property / invariant tests ------------------------------------------

(test property-invert-involutive
  "Inverting twice restores the original pixels."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 16 16))
      (vips:with-images ((once (vips:invert img))
                         (twice (vips:invert once)))
        (dolist (xy '((0 0) (5 7) (15 15)))
          (is (approx= (first (vips:getpoint img (first xy) (second xy)))
                       (first (vips:getpoint twice (first xy) (second xy))))))))))

(test property-flip-twice-identity
  "Flipping horizontally twice restores the image."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 12 8))
      (vips:with-images ((f1 (vips:flip img :horizontal))
                         (f2 (vips:flip f1 :horizontal)))
        (is (approx= (first (vips:getpoint img 3 5))
                     (first (vips:getpoint f2 3 5))))
        (is (approx= (first (vips:getpoint img 11 7))
                     (first (vips:getpoint f2 11 7))))))))

(test property-rotate-360-identity
  "Four 90-degree rotations restore the image and its dimensions."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 9 5))
      (vips:with-images ((r1 (vips:rotate img :d90))
                         (r2 (vips:rotate r1 :d90))
                         (r3 (vips:rotate r2 :d90))
                         (r4 (vips:rotate r3 :d90)))
        (is (= 9 (vips:width r4)))
        (is (= 5 (vips:height r4)))
        (is (approx= (first (vips:getpoint img 4 2))
                     (first (vips:getpoint r4 4 2))))))))

(test property-add-subtract-inverse
  "(a + b) - b = a, pixelwise."
  (with-fixture initialized ()
    (vips:with-images ((a (solid-image 8 8 :value 60))
                       (b (solid-image 8 8 :value 25)))
      (vips:with-images ((sum (vips:add a b))
                         (back (vips:subtract sum b)))
        (is (approx= 60.0d0 (first (vips:getpoint back 0 0))))))))

;;; --- Large image (lazy pipeline) -----------------------------------------

(test large-image-pipeline
  "A large image flows through a lazy pipeline without materialising fully."
  (with-fixture initialized ()
    (vips:with-image (big (vips:black 4000 3000 :bands 3))
      (is (= 4000 (vips:width big)))
      (vips:with-image (small (vips:resize big 0.1))
        (is (= 400 (vips:width small)))
        (is (approx= 0.0d0 (vips:avg small)))))))
