;;;; package.lisp --- Package definition for cl-vips

(defpackage #:vips
  (:use #:cl)
  (:nicknames #:cl-vips)
  (:export
   ;; lifecycle / core
   #:init
   #:shutdown
   #:initialized-p
   #:version
   #:version-string
   #:set-leak-checking
   #:*library-directories*
   #:load-libraries

   ;; conditions
   #:vips-error
   #:vips-error-message

   ;; image type / lifecycle
   #:image
   #:imagep
   #:image-live-p
   #:unref
   #:with-image
   #:with-images
   #:with-image-pool
   #:keep
   #:pointer-of

   ;; loading / saving
   #:load-image
   #:save-image
   #:image-from-octets
   #:write-to-octets
   #:image-from-pixels
   #:write-to-memory
   #:image-to-array
   #:image-from-array

   ;; header / introspection
   #:width
   #:height
   #:bands
   #:image-format
   #:interpretation
   #:filename
   #:get-double
   #:get-int
   #:get-string
   #:getpoint

   ;; creation
   #:black

   ;; geometry / transforms
   #:resize
   #:crop
   #:embed
   #:flip
   #:rotate

   ;; pixel / colour
   #:invert
   #:linear
   #:gaussblur
   #:colourspace
   #:cast

   ;; bands
   #:extract-band
   #:bandjoin

   ;; arithmetic
   #:add
   #:subtract
   #:multiply

   ;; statistics
   #:avg
   #:image-min
   #:image-max
   #:deviate

   ;; generic operation engine (Phase 1)
   #:call-operation
   #:define-operation
   #:image-abs
   #:sign
   #:flatten
   #:gamma
   #:affine
   #:arrayjoin

   ;; introspection + auto-wrappers (Phase 4)
   #:operation-arguments
   #:operation-required-inputs
   #:operation-optional-inputs
   #:operation-outputs
   #:describe-operation
   #:make-operation-caller
   #:defvips
   #:list-operations
   #:operation-groups
   #:operations-in-group
   #:defvips-all))
