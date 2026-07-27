;;;; tests/image-tests.lisp --- Loading, saving, memory I/O and introspection

(in-package #:vips/test)

(def-suite image-suite :description "Image I/O and introspection."
  :in all-tests)
(in-suite image-suite)

(test from-pixels-dimensions
  "IMAGE-FROM-PIXELS reports the dimensions and bands it was given."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 7 5 :bands 3 :value 200))
      (is (= 7 (vips:width img)))
      (is (= 5 (vips:height img)))
      (is (= 3 (vips:bands img)))
      (is (eq :uchar (vips:image-format img))))))

(test from-pixels-values
  "Raw pixel data survives the round trip and is readable via GETPOINT."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4 :bands 1 :value 137))
      (is (equal '(137.0d0) (vips:getpoint img 0 0)))
      (is (equal '(137.0d0) (vips:getpoint img 3 3))))))

(test getpoint-multiband
  "GETPOINT returns one value per band."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 2 2 :bands 3 :value 50))
      (let ((px (vips:getpoint img 1 1)))
        (is (= 3 (length px)))
        (is (every (lambda (v) (approx= v 50.0d0)) px))))))

(test ramp-values
  "A programmatic ramp has the expected per-pixel values."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 8 8))
      (is (approx= 0.0d0 (first (vips:getpoint img 0 0))))
      (is (approx= 3.0d0 (first (vips:getpoint img 1 2))))
      (is (approx= 14.0d0 (first (vips:getpoint img 7 7)))))))

(test save-and-load-png-roundtrip
  "Saving to a PNG file and reloading preserves size, bands and pixels."
  (with-fixture initialized ()
    (with-temp-file (path "png")
      (vips:with-image (img (ramp-image 16 12))
        (vips:save-image img path)
        (is-true (probe-file path)))
      (vips:with-image (loaded (vips:load-image path))
        (is (= 16 (vips:width loaded)))
        (is (= 12 (vips:height loaded)))
        (is (= 1 (vips:bands loaded)))
        (is (approx= 5.0d0 (first (vips:getpoint loaded 2 3))))))))

(test octets-roundtrip
  "WRITE-TO-OCTETS then IMAGE-FROM-OCTETS reproduces the image in memory."
  (with-fixture initialized ()
    (vips:with-image (img (ramp-image 10 10))
      (let ((bytes (vips:write-to-octets img ".png")))
        (is (typep bytes '(vector (unsigned-byte 8))))
        (is (plusp (length bytes)))
        ;; PNG magic number
        (is (= #x89 (aref bytes 0)))
        (is (= #x50 (aref bytes 1)))
        (vips:with-image (decoded (vips:image-from-octets bytes))
          (is (= 10 (vips:width decoded)))
          (is (= 10 (vips:height decoded)))
          (is (approx= 6.0d0 (first (vips:getpoint decoded 3 3)))))))))

(test filename-of-loaded-image
  "A loaded image reports the filename it came from."
  (with-fixture initialized ()
    (with-temp-file (path "png")
      (vips:with-image (img (solid-image 4 4))
        (vips:save-image img path))
      (vips:with-image (loaded (vips:load-image path))
        (is (search (pathname-name path) (or (vips:filename loaded) "")))))))

(test metadata-accessors
  "Header integer/double accessors return sane values for known fields."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 6 4 :bands 3))
      ;; width/height are exposed as integer metadata fields too
      (is (= 6 (vips:get-int img "width")))
      (is (= 4 (vips:get-int img "height")))
      ;; xres is a double field present on every image
      (is (numberp (vips:get-double img "xres"))))))

(test load-missing-file-signals
  "Loading a nonexistent file signals VIPS-ERROR."
  (with-fixture initialized ()
    (signals vips:vips-error
      (vips:load-image "/no/such/file/definitely-missing.png"))))

;;; --- Raw pixel array I/O -------------------------------------------------

(test image-array-round-trip-uchar
  "image-from-array then image-to-array reproduces a uchar array exactly."
  (with-fixture initialized ()
    (let ((arr (make-array '(3 4 3) :element-type '(unsigned-byte 8))))
      (dotimes (y 3)
        (dotimes (x 4)
          (dotimes (k 3)
            (setf (aref arr y x k) (mod (+ (* 40 y) (* 7 x) (* 3 k)) 256)))))
      (vips:with-image (img (vips:image-from-array arr))
        (is (= 4 (vips:width img)))
        (is (= 3 (vips:height img)))
        (is (= 3 (vips:bands img)))
        (is (eq :uchar (vips:image-format img)))
        (is (equalp arr (vips:image-to-array img)))))))

(test image-array-rank-2-single-band
  "A rank-2 array becomes a single-band image."
  (with-fixture initialized ()
    (let ((arr (make-array '(2 3) :element-type '(unsigned-byte 8)
                                  :initial-contents '((1 2 3) (4 5 6)))))
      (vips:with-image (img (vips:image-from-array arr))
        (is (= 1 (vips:bands img)))
        (is (= 3 (vips:width img)))
        (is (equal '(4.0d0) (vips:getpoint img 0 1)))))))

(test image-array-round-trip-float
  "Float arrays round-trip through the :FLOAT format."
  (with-fixture initialized ()
    (let ((arr (make-array '(2 2 1) :element-type 'single-float
                                    :initial-element 1.5f0)))
      (setf (aref arr 1 1 0) -3.25f0)
      (vips:with-image (img (vips:image-from-array arr))
        (is (eq :float (vips:image-format img)))
        (is (equalp arr (vips:image-to-array img)))))))

(test write-to-memory-geometry
  "write-to-memory returns the raw bytes and correct geometry."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 5 4 :bands 3 :value 200))
      (multiple-value-bind (octets w h b format) (vips:write-to-memory img)
        (is (typep octets '(vector (unsigned-byte 8))))
        (is (= (* 5 4 3) (length octets)))   ; uchar => 1 byte/sample
        (is (= 5 w)) (is (= 4 h)) (is (= 3 b))
        (is (eq :uchar format))
        (is (= 200 (aref octets 0)))))))
