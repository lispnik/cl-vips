;;;; tests/error-tests.lisp --- Error propagation and edge cases

(in-package #:vips/test)

(def-suite error-suite :description "Error handling."
  :in all-tests)
(in-suite error-suite)

(test crop-out-of-bounds-signals
  "Cropping outside the image bounds signals VIPS-ERROR."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4))
      (signals vips:vips-error
        (vips:crop img 0 0 100 100)))))

(test error-message-is-populated
  "A failing operation produces a non-empty error message."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4))
      (handler-case
          (progn (vips:crop img 10 10 50 50)
                 (fail "expected an error"))
        (vips:vips-error (e)
          (is (stringp (vips:vips-error-message e)))
          (is (plusp (length (vips:vips-error-message e)))))))))

(test bad-metadata-field-signals
  "Requesting a missing metadata field signals VIPS-ERROR."
  (with-fixture initialized ()
    (vips:with-image (img (solid-image 4 4))
      (signals vips:vips-error
        (vips:get-int img "no-such-field-xyzzy")))))

(test decode-garbage-octets-signals
  "Decoding non-image bytes signals VIPS-ERROR rather than crashing."
  (with-fixture initialized ()
    (let ((junk (make-array 8 :element-type '(unsigned-byte 8)
                              :initial-contents '(1 2 3 4 5 6 7 8))))
      (signals vips:vips-error
        (vips:image-from-octets junk)))))

(test vips-error-is-an-error
  "VIPS-ERROR is a subtype of CL:ERROR and carries a message reader."
  (is (subtypep 'vips:vips-error 'error))
  (let ((c (make-condition 'vips:vips-error :message "boom")))
    (is (string= "boom" (vips:vips-error-message c)))))
