;;;; tests/core-tests.lisp --- Lifecycle, versioning and wrapper semantics

(in-package #:vips/test)

(def-suite core-suite :description "Core lifecycle and versioning."
  :in all-tests)
(in-suite core-suite)

(test init-is-idempotent
  "INIT can be called repeatedly and reports initialized."
  (is (vips:init))
  (is (vips:init))
  (is-true (vips:initialized-p)))

(test version-values
  "VERSION returns three non-negative integers and a dotted string."
  (with-fixture initialized ()
    (multiple-value-bind (major minor micro) (vips:version)
      (is (integerp major))
      (is (integerp minor))
      (is (integerp micro))
      (is (>= major 8) "libvips major version should be >= 8")
      (is (string= (vips:version-string)
                   (format nil "~d.~d.~d" major minor micro))))))

(test image-wrapper-liveness
  "A fresh image is live; UNREF makes it dead and idempotent."
  (with-fixture initialized ()
    (let ((img (solid-image 4 4)))
      (is-true (vips:imagep img))
      (is-true (vips:image-live-p img))
      (vips:unref img)
      (is-false (vips:image-live-p img))
      ;; second unref must be a harmless no-op
      (finishes (vips:unref img)))))

(test use-after-free-signals
  "Touching a freed image signals an error rather than crashing."
  (with-fixture initialized ()
    (let ((img (solid-image 4 4)))
      (vips:unref img)
      (signals error (vips:width img)))))

(test with-image-frees-on-exit
  "WITH-IMAGE frees its image even on non-local exit."
  (with-fixture initialized ()
    (let ((saved nil))
      (ignore-errors
       (vips:with-image (img (solid-image 4 4))
         (setf saved img)
         (is-true (vips:image-live-p img))
         (error "bail")))
      (is-false (vips:image-live-p saved)))))

(test with-images-multiple
  "WITH-IMAGES binds and frees several images."
  (with-fixture initialized ()
    (let (a b)
      (vips:with-images ((x (solid-image 2 2))
                         (y (solid-image 3 3)))
        (setf a x b y)
        (is (= 2 (vips:width x)))
        (is (= 3 (vips:width y))))
      (is-false (vips:image-live-p a))
      (is-false (vips:image-live-p b)))))

(test with-image-pool-frees-everything
  "WITH-IMAGE-POOL frees every image made in its extent, incl. operation
results, even on a non-local exit."
  (with-fixture initialized ()
    (let ((collected '()))
      (ignore-errors
       (vips:with-image-pool
         ;; a loop making an unknown number of temporaries, plus derived images
         (dotimes (i 4)
           (let* ((base (solid-image 4 4 :value (* 10 i)))
                  (inv (vips:invert base)))
             (push base collected)
             (push inv collected)))
         (is (every #'vips:image-live-p collected))
         (error "bail out of the pool")))
      (is (= 8 (length collected)))
      (is (notany #'vips:image-live-p collected)))))

(test with-image-pool-keep-survives
  "KEEP removes an image from the pool so it outlives the pool."
  (with-fixture initialized ()
    (let ((survivor nil))
      (vips:with-image-pool
        (solid-image 4 4)                     ; a temporary: freed by the pool
        (setf survivor (vips:keep (solid-image 5 5 :value 99))))
      (is-true (vips:image-live-p survivor))   ; kept alive
      (is (= 5 (vips:width survivor)))
      (vips:unref survivor))))                 ; caller now owns it

(test nested-image-pools
  "Nested pools each free only their own images."
  (with-fixture initialized ()
    (let (outer inner)
      (vips:with-image-pool
        (setf outer (solid-image 2 2))
        (vips:with-image-pool
          (setf inner (solid-image 3 3)))
        (is-false (vips:image-live-p inner))   ; inner pool freed it
        (is-true (vips:image-live-p outer)))   ; still alive in outer
      (is-false (vips:image-live-p outer)))))

(test leak-checking-toggles
  "SET-LEAK-CHECKING can be turned on and off without error."
  (with-fixture initialized ()
    (is-true (vips:set-leak-checking t))
    (is-false (vips:set-leak-checking nil))))

#+sbcl
(test concurrent-init-is-safe
  "Many threads initializing and running an operation at once is safe
(thread-locked init, thread-safe libvips ops)."
  (let ((threads (loop repeat 8
                       collect (sb-thread:make-thread
                                (lambda ()
                                  (vips:init)
                                  (vips:with-image (img (solid-image 8 8 :value 42))
                                    (vips:avg img)))))))
    (is (every (lambda (th) (approx= 42.0d0 (sb-thread:join-thread th)))
               threads))))
