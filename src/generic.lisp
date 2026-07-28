;;;; generic.lisp --- Generic VipsOperation engine (Phase 1)
;;;;
;;;; Instead of hand-binding every libvips operation, CALL-OPERATION drives the
;;;; generic VipsOperation API: create an operation by nickname, set its input
;;;; arguments as GObject properties, build it, and read the output back.  This
;;;; is how pyvips / ruby-vips achieve full coverage.
;;;;
;;;; Phase 1 supports these GValue kinds: boolean, int, uint, int64, uint64,
;;;; float, double, string, enum, flags and object (VipsImage).  Arrays and
;;;; blobs are Phase 2; optional/keyword-arg and multi-output introspection is
;;;; Phase 4.

(in-package #:vips)

;;; ---------------------------------------------------------------------------
;;; GType / GValue / GParamSpec foreign layer
;;; ---------------------------------------------------------------------------

;; GType is a gsize; on every LP64 platform we target that is an unsigned long.
(cffi:defctype gtype :unsigned-long)

;; struct _GValue { GType g_type; union {...} data[2]; } -- 24 bytes on LP64.
(cffi:defcstruct g-value
  (g-type gtype)
  (data :uint64 :count 2))

;; struct _GParamSpec { GTypeInstance; const gchar *name; GParamFlags flags;
;;                      GType value_type; GType owner_type; ... }
;; The layout up to VALUE-TYPE is frozen public ABI; CFFI handles alignment.
(cffi:defcstruct g-param-spec
  (g-type-instance :pointer)
  (name :pointer)
  (flags :uint)
  (value-type gtype)
  (owner-type gtype))

;; --- GType introspection ---
(cffi:defcfun ("g_type_from_name" %g-type-from-name) gtype (name :string))
(cffi:defcfun ("g_type_fundamental" %g-type-fundamental) gtype (type gtype))

;; --- GObject property access ---
(cffi:defcfun ("g_object_class_find_property" %g-object-class-find-property)
    :pointer
  (class :pointer) (property-name :string))
(cffi:defcfun ("g_object_get_property" %g-object-get-property) :void
  (object :pointer) (name :string) (value :pointer))
(cffi:defcfun ("g_object_set_property" %g-object-set-property) :void
  (object :pointer) (name :string) (value :pointer))
(cffi:defcfun ("g_object_ref" %g-object-ref) :pointer (object :pointer))

;; --- GValue lifecycle ---
(cffi:defcfun ("g_value_init" %g-value-init) :pointer (value :pointer) (type gtype))
(cffi:defcfun ("g_value_unset" %g-value-unset) :void (value :pointer))

;; --- GValue setters ---
(cffi:defcfun ("g_value_set_boolean" %g-value-set-boolean) :void (v :pointer) (x :int))
(cffi:defcfun ("g_value_set_int" %g-value-set-int) :void (v :pointer) (x :int))
(cffi:defcfun ("g_value_set_uint" %g-value-set-uint) :void (v :pointer) (x :uint))
(cffi:defcfun ("g_value_set_int64" %g-value-set-int64) :void (v :pointer) (x :int64))
(cffi:defcfun ("g_value_set_uint64" %g-value-set-uint64) :void (v :pointer) (x :uint64))
(cffi:defcfun ("g_value_set_float" %g-value-set-float) :void (v :pointer) (x :float))
(cffi:defcfun ("g_value_set_double" %g-value-set-double) :void (v :pointer) (x :double))
(cffi:defcfun ("g_value_set_string" %g-value-set-string) :void (v :pointer) (x :string))
(cffi:defcfun ("g_value_set_enum" %g-value-set-enum) :void (v :pointer) (x :int))
(cffi:defcfun ("g_value_set_flags" %g-value-set-flags) :void (v :pointer) (x :uint))
(cffi:defcfun ("g_value_set_object" %g-value-set-object) :void (v :pointer) (o :pointer))

;; --- GValue getters ---
(cffi:defcfun ("g_value_get_boolean" %g-value-get-boolean) :int (v :pointer))
(cffi:defcfun ("g_value_get_int" %g-value-get-int) :int (v :pointer))
(cffi:defcfun ("g_value_get_uint" %g-value-get-uint) :uint (v :pointer))
(cffi:defcfun ("g_value_get_int64" %g-value-get-int64) :int64 (v :pointer))
(cffi:defcfun ("g_value_get_uint64" %g-value-get-uint64) :uint64 (v :pointer))
(cffi:defcfun ("g_value_get_float" %g-value-get-float) :float (v :pointer))
(cffi:defcfun ("g_value_get_double" %g-value-get-double) :double (v :pointer))
(cffi:defcfun ("g_value_get_string" %g-value-get-string) :string (v :pointer))
(cffi:defcfun ("g_value_get_enum" %g-value-get-enum) :int (v :pointer))
(cffi:defcfun ("g_value_get_flags" %g-value-get-flags) :uint (v :pointer))
(cffi:defcfun ("g_value_get_object" %g-value-get-object) :pointer (v :pointer))

;; --- Boxed array types (Phase 2) ---
;; These get_type functions both register the type (if needed) and return its
;; GType, which we dispatch on exactly (their fundamental is merely GBoxed).
(cffi:defcfun ("vips_array_int_get_type" %vips-array-int-get-type) gtype)
(cffi:defcfun ("vips_array_double_get_type" %vips-array-double-get-type) gtype)

(cffi:defcfun ("vips_value_set_array_int" %vips-value-set-array-int) :void
  (value :pointer) (array :pointer) (n :int))
(cffi:defcfun ("vips_value_get_array_int" %vips-value-get-array-int) :pointer
  (value :pointer) (n :pointer))
(cffi:defcfun ("vips_value_set_array_double" %vips-value-set-array-double) :void
  (value :pointer) (array :pointer) (n :int))
(cffi:defcfun ("vips_value_get_array_double" %vips-value-get-array-double) :pointer
  (value :pointer) (n :pointer))

;; --- Boxed image-array and blob types (Phase 3) ---
(cffi:defcfun ("vips_array_image_get_type" %vips-array-image-get-type) gtype)
(cffi:defcfun ("vips_blob_get_type" %vips-blob-get-type) gtype)

;; set_array_image(value, n) allocates n empty slots (value must already be
;; g_value_init'd to VIPS_TYPE_ARRAY_IMAGE); the caller fills the slots with
;; ref'd image pointers obtained from get_array_image.
(cffi:defcfun ("vips_value_set_array_image" %vips-value-set-array-image) :void
  (value :pointer) (n :int))
(cffi:defcfun ("vips_value_get_array_image" %vips-value-get-array-image) :pointer
  (value :pointer) (n :pointer))

;; vips takes ownership of DATA (g_malloc'd) and frees it with g_free.
(cffi:defcfun ("vips_value_set_blob_free" %vips-value-set-blob-free) :void
  (value :pointer) (data :pointer) (length :unsigned-long))
(cffi:defcfun ("vips_value_get_blob" %vips-value-get-blob) :pointer
  (value :pointer) (length :pointer))

(cffi:defcfun ("g_malloc" %g-malloc) :pointer (n :unsigned-long))

;; --- VipsOperation + enum nick helpers ---
(cffi:defcfun ("vips_operation_new" %vips-operation-new) :pointer (name :string))
(cffi:defcfun ("vips_cache_operation_buildp" %vips-cache-operation-buildp) :int
  (operation :pointer))
(cffi:defcfun ("vips_enum_from_nick" %vips-enum-from-nick) :int
  (domain :string) (type gtype) (nick :string))
(cffi:defcfun ("vips_enum_nick" %vips-enum-nick) :string (type gtype) (value :int))

;; --- Argument introspection (Phase 4) ---
;; vips_object_get_args fills NAMES with a (const char **), FLAGS with an
;; (int *), and N-ARGS with the count.  All arrays are owned by the object.
(cffi:defcfun ("vips_object_get_args" %vips-object-get-args) :int
  (object :pointer) (names :pointer) (flags :pointer) (n-args :pointer))

;; --- Operation enumeration (Phase 4, defvips-all) ---
(cffi:defcfun ("g_type_parent" %g-type-parent) gtype (type gtype))
(cffi:defcfun ("g_type_test_flags" %g-type-test-flags) :int
  (type gtype) (flags :uint))
(cffi:defcfun ("vips_nickname_find" %vips-nickname-find) :string (type gtype))
;; vips_type_map_all recursively visits every subtype of BASE, calling FN.
(cffi:defcfun ("vips_type_map_all" %vips-type-map-all) :pointer
  (base gtype) (fn :pointer) (a :pointer))

(defconstant +g-type-flag-abstract+ 16
  "G_TYPE_FLAG_ABSTRACT: an abstract (non-instantiable) type.")

;;; ---------------------------------------------------------------------------
;;; Fundamental GType cache
;;; ---------------------------------------------------------------------------

(defvar *gtypes* nil
  "Plist of cached fundamental GTypes, populated lazily by ENSURE-GTYPES.")

(defun ensure-gtypes ()
  "Resolve and cache the fundamental GTypes we dispatch on. Requires libvips
to be initialized (which registers the GObject type system). Thread-safe."
  (unless *gtypes*
    (ensure-init)
    (with-init-lock
     (unless *gtypes*
      (setf *gtypes*
          (list :boolean (%g-type-from-name "gboolean")
                :int     (%g-type-from-name "gint")
                :uint    (%g-type-from-name "guint")
                :int64   (%g-type-from-name "gint64")
                :uint64  (%g-type-from-name "guint64")
                :float   (%g-type-from-name "gfloat")
                :double  (%g-type-from-name "gdouble")
                :string  (%g-type-from-name "gchararray")
                :enum    (%g-type-from-name "GEnum")
                :flags   (%g-type-from-name "GFlags")
                :object  (%g-type-from-name "GObject")
                :array-int    (%vips-array-int-get-type)
                :array-double (%vips-array-double-get-type)
                :array-image  (%vips-array-image-get-type)
                :blob         (%vips-blob-get-type))))))
  *gtypes*)

(defun %gt (key) (getf *gtypes* key))

(defun %gvalue-kind (value-type)
  "Classify VALUE-TYPE into a keyword we know how to box/unbox."
  (let ((fundamental (%g-type-fundamental value-type)))
    (cond ((= value-type (%gt :boolean)) :boolean)
          ((= value-type (%gt :int))     :int)
          ((= value-type (%gt :uint))    :uint)
          ((= value-type (%gt :int64))   :int64)
          ((= value-type (%gt :uint64))  :uint64)
          ((= value-type (%gt :float))   :float)
          ((= value-type (%gt :double))  :double)
          ((= value-type (%gt :string))  :string)
          ((= value-type (%gt :array-int))    :array-int)
          ((= value-type (%gt :array-double)) :array-double)
          ((= value-type (%gt :array-image))  :array-image)
          ((= value-type (%gt :blob))         :blob)
          ((= fundamental (%gt :enum))   :enum)
          ((= fundamental (%gt :flags))  :flags)
          ((= fundamental (%gt :object)) :object)
          (t :unsupported))))

;;; ---------------------------------------------------------------------------
;;; Property value type lookup
;;; ---------------------------------------------------------------------------

(defun %property-value-type (op name)
  "Return the GType of property NAME on operation OP, signalling VIPS-ERROR if
there is no such property."
  ;; The instance's first word is its GTypeClass* (== G_OBJECT_GET_CLASS).
  (let* ((class (cffi:mem-ref op :pointer))
         (pspec (%g-object-class-find-property class name)))
    (when (cffi:null-pointer-p pspec)
      (error 'vips-error
             :message (format nil "no argument named ~s for this operation"
                              name)))
    (cffi:foreign-slot-value pspec '(:struct g-param-spec) 'value-type)))

;;; ---------------------------------------------------------------------------
;;; Boxing / unboxing
;;; ---------------------------------------------------------------------------

(defmacro %with-gvalue ((var type) &body body)
  "Bind VAR to a zeroed, g_value_init'd GValue of GType TYPE; g_value_unset on
exit."
  `(cffi:with-foreign-object (,var '(:struct g-value))
     (dotimes (%i (cffi:foreign-type-size '(:struct g-value)))
       (setf (cffi:mem-aref ,var :uint8 %i) 0))
     (%g-value-init ,var ,type)
     (unwind-protect (progn ,@body)
       (%g-value-unset ,var))))

(defun %as-list (value)
  "Coerce VALUE to a list for an array argument. A lone number becomes a
one-element list (matching libvips' scalar-to-array promotion)."
  (cond ((null value) '())
        ((numberp value) (list value))
        ((listp value) value)
        ((vectorp value) (coerce value 'list))
        (t (error 'vips-error
                  :message (format nil "cannot use ~s as an array argument"
                                   value)))))

(defun %set-array-int (gv value)
  (let* ((items (%as-list value)) (n (length items)))
    (if (zerop n)
        (%vips-value-set-array-int gv (cffi:null-pointer) 0)
        (cffi:with-foreign-object (arr :int n)
          (loop for i from 0 for x in items
                do (setf (cffi:mem-aref arr :int i) (round x)))
          (%vips-value-set-array-int gv arr n)))))

(defun %set-array-double (gv value)
  (let* ((items (%as-list value)) (n (length items)))
    (if (zerop n)
        (%vips-value-set-array-double gv (cffi:null-pointer) 0)
        (cffi:with-foreign-object (arr :double n)
          (loop for i from 0 for x in items
                do (setf (cffi:mem-aref arr :double i) (coerce x 'double-float)))
          (%vips-value-set-array-double gv arr n)))))

(defun %get-array-int (gv)
  (cffi:with-foreign-object (np :int)
    (let ((ptr (%vips-value-get-array-int gv np)))
      (loop for i below (cffi:mem-ref np :int)
            collect (cffi:mem-aref ptr :int i)))))

(defun %get-array-double (gv)
  (cffi:with-foreign-object (np :int)
    (let ((ptr (%vips-value-get-array-double gv np)))
      (loop for i below (cffi:mem-ref np :int)
            collect (cffi:mem-aref ptr :double i)))))

(defun %as-image-list (value)
  "Coerce VALUE (a single IMAGE, or a list/vector of IMAGEs) to a list of
IMAGEs."
  (cond ((imagep value) (list value))
        ((listp value) value)
        ((vectorp value) (coerce value 'list))
        (t (error 'vips-error
                  :message (format nil "cannot use ~s as an image array" value)))))

(defun %set-array-image (gv value)
  "Box a list of IMAGEs into GV (a VIPS_TYPE_ARRAY_IMAGE GValue). The array
takes a reference on each image, so we ref every slot we fill."
  (let* ((images (%as-image-list value))
         (n (length images)))
    (%vips-value-set-array-image gv n)
    (let ((array (%vips-value-get-array-image gv (cffi:null-pointer))))
      (loop for i from 0 for img in images
            for ptr = (pointer-of img)
            do (%g-object-ref ptr)
               (setf (cffi:mem-aref array :pointer i) ptr)))))

(defun %get-array-image (gv)
  "Unbox a VIPS_TYPE_ARRAY_IMAGE GValue into a list of owned IMAGEs (we take a
ref on each, since the array only lends them to us)."
  (cffi:with-foreign-object (np :int)
    (let ((array (%vips-value-get-array-image gv np)))
      (loop for i below (cffi:mem-ref np :int)
            for ptr = (cffi:mem-aref array :pointer i)
            collect (progn (%g-object-ref ptr) (wrap-image ptr))))))

(defun %set-blob (gv octets)
  "Box OCTETS (a vector of (unsigned-byte 8)) into GV as a VipsBlob. The bytes
are copied into g_malloc'd memory that vips takes ownership of."
  (let* ((n (length octets))
         (mem (%g-malloc (max n 1))))
    (dotimes (i n)
      (setf (cffi:mem-aref mem :uint8 i) (aref octets i)))
    (%vips-value-set-blob-free gv mem n)))

(defun %get-blob (gv)
  "Unbox a VipsBlob GValue into a fresh (unsigned-byte 8) vector."
  (cffi:with-foreign-object (np :unsigned-long)
    (let* ((ptr (%vips-value-get-blob gv np))
           (n (cffi:mem-ref np :unsigned-long))
           (out (make-array n :element-type '(unsigned-byte 8))))
      (unless (cffi:null-pointer-p ptr)
        (dotimes (i n)
          (setf (aref out i) (cffi:mem-aref ptr :uint8 i))))
      out)))

(defun %enum-value (value-type value)
  "Coerce VALUE (integer, keyword or string) to the integer for enum GType
VALUE-TYPE."
  (etypecase value
    (integer value)
    ((or symbol string)
     (let ((n (%vips-enum-from-nick "cl-vips" value-type
                                    (string-downcase (string value)))))
       (when (minusp n)
         (raise-vips-error))
       n))))

(defun %set-property (op name value)
  "Set input argument NAME of operation OP to VALUE, coercing VALUE to the
property's declared GType."
  (let* ((value-type (%property-value-type op name))
         (kind (%gvalue-kind value-type)))
    (%with-gvalue (gv value-type)
      (ecase kind
        (:boolean (%g-value-set-boolean gv (if value 1 0)))
        (:int     (%g-value-set-int gv (round value)))
        (:uint    (%g-value-set-uint gv (round value)))
        (:int64   (%g-value-set-int64 gv (round value)))
        (:uint64  (%g-value-set-uint64 gv (round value)))
        (:float   (%g-value-set-float gv (coerce value 'single-float)))
        (:double  (%g-value-set-double gv (coerce value 'double-float)))
        (:string  (%g-value-set-string gv (string value)))
        (:enum    (%g-value-set-enum gv (%enum-value value-type value)))
        (:flags   (%g-value-set-flags gv (round value)))
        (:object  (%g-value-set-object gv (pointer-of value)))
        (:array-int    (%set-array-int gv value))
        (:array-double (%set-array-double gv value))
        (:array-image  (%set-array-image gv value))
        (:blob         (%set-blob gv value))
        (:unsupported
         (error 'vips-error
                :message (format nil "unsupported argument type for ~s (Phase 1)"
                                 name))))
      (%g-object-set-property op name gv))))

(defun %get-property (op name)
  "Read output argument NAME of operation OP and return it as a Lisp value
(an IMAGE for object-typed outputs)."
  (let* ((value-type (%property-value-type op name))
         (kind (%gvalue-kind value-type)))
    (%with-gvalue (gv value-type)
      (%g-object-get-property op name gv)
      (ecase kind
        (:boolean (not (zerop (%g-value-get-boolean gv))))
        (:int     (%g-value-get-int gv))
        (:uint    (%g-value-get-uint gv))
        (:int64   (%g-value-get-int64 gv))
        (:uint64  (%g-value-get-uint64 gv))
        (:float   (%g-value-get-float gv))
        (:double  (%g-value-get-double gv))
        (:string  (%g-value-get-string gv))
        (:enum    (let ((nick (%vips-enum-nick value-type (%g-value-get-enum gv))))
                    (and nick (intern (string-upcase nick) :keyword))))
        (:flags   (%g-value-get-flags gv))
        (:array-int    (%get-array-int gv))
        (:array-double (%get-array-double gv))
        (:array-image  (%get-array-image gv))
        (:blob         (%get-blob gv))
        (:object  (let ((ptr (%g-value-get-object gv)))
                    (unless (cffi:null-pointer-p ptr)
                      ;; The GValue owns one ref that g_value_unset will drop;
                      ;; take our own before it does.
                      (%g-object-ref ptr)
                      (wrap-image ptr))))
        (:unsupported
         (error 'vips-error
                :message (format nil "unsupported output type for ~s (Phase 1)"
                                 name)))))))

;;; ---------------------------------------------------------------------------
;;; Argument introspection (Phase 4)
;;; ---------------------------------------------------------------------------

;; VipsArgumentFlags bits we care about.
(defconstant +arg-required+   1)
(defconstant +arg-input+     16)
(defconstant +arg-output+    32)
(defconstant +arg-deprecated+ 64)
(defconstant +arg-modify+   128)

(declaim (inline %arg-input-p %arg-output-p %arg-required-p %arg-deprecated-p
                 %arg-modify-p))
(defun %arg-input-p     (flags) (logtest flags +arg-input+))
(defun %arg-output-p    (flags) (logtest flags +arg-output+))
(defun %arg-required-p  (flags) (logtest flags +arg-required+))
(defun %arg-deprecated-p (flags) (logtest flags +arg-deprecated+))
(defun %arg-modify-p    (flags) (logtest flags +arg-modify+))

;; Draw and similar in-place operations take an INPUT image flagged MODIFY that
;; they mutate; the mutated image *is* the result. vips_image_copy_memory gives
;; us an owned, writable memory copy to hand such an argument.
(cffi:defcfun ("vips_image_copy_memory" %vips-image-copy-memory) :pointer
  (image :pointer))

(defun %object-arguments (op)
  "Return a list of (NAME . FLAGS) conses for every argument of VipsObject OP."
  (cffi:with-foreign-objects ((names :pointer) (flags :pointer) (n :int))
    (unless (zerop (%vips-object-get-args op names flags n))
      (raise-vips-error))
    (let ((name-array (cffi:mem-ref names :pointer))
          (flag-array (cffi:mem-ref flags :pointer))
          (count (cffi:mem-ref n :int)))
      (loop for i below count
            collect (cons (cffi:mem-aref name-array :string i)
                          (cffi:mem-aref flag-array :int i))))))

(defun %output-names (op)
  "Names of OP's non-deprecated output arguments."
  (loop for (name . flags) in (%object-arguments op)
        when (and (%arg-output-p flags) (not (%arg-deprecated-p flags)))
          collect name))

;;; ---------------------------------------------------------------------------
;;; The engine
;;; ---------------------------------------------------------------------------

(defun %set-object-pointer (op name pointer)
  "Set object-valued argument NAME of OP directly from a raw VipsObject
POINTER (used for MODIFY image copies)."
  (let ((value-type (%property-value-type op name)))
    (%with-gvalue (gv value-type)
      (%g-value-set-object gv pointer)
      (%g-object-set-property op name gv))))

(defun call-operation (nickname inputs &key (output "out") outputs)
  "Call the libvips operation named NICKNAME (a string such as \"gaussblur\").
INPUTS is a plist of libvips argument names (strings) to Lisp values; images
are passed as IMAGE objects, enums as keywords or strings, numbers/booleans as
themselves.

By default returns the value of the OUTPUT argument (default \"out\"), wrapping
object outputs as an IMAGE.  If OUTPUTS is given it overrides OUTPUT and the
function returns multiple values, one per requested output: OUTPUTS may be a
list of argument names, or :ALL for every non-deprecated output argument.

Signals VIPS-ERROR on any failure."
  (ensure-gtypes)
  (let ((op (%vips-operation-new nickname))
        (modify-copies '())   ; owned copies we made for MODIFY inputs
        (primary-modify nil)  ; the first, which becomes the result for draw ops
        (returned nil))       ; the copy handed to the caller (not to be unref'd)
    (when (cffi:null-pointer-p op)
      ;; unknown operation name
      (raise-vips-error))
    (unwind-protect
         (let* ((args (%object-arguments op))
                (flags-of (lambda (name) (cdr (assoc name args :test #'string=)))))
           ;; Set inputs. An INPUT+MODIFY image argument (draw ops) is mutated
           ;; in place, so pass a memory copy we own -- that copy is the result.
           (loop for (name value) on inputs by #'cddr
                 for flags = (funcall flags-of name)
                 do (if (and flags (%arg-modify-p flags) (%arg-input-p flags)
                             (imagep value))
                        (let ((copy (%vips-image-copy-memory (pointer-of value))))
                          (when (cffi:null-pointer-p copy)
                            (raise-vips-error))
                          (push copy modify-copies)
                          (unless primary-modify (setf primary-modify copy))
                          (%set-object-pointer op name copy))
                        (%set-property op name value)))
           (cffi:with-foreign-object (opp :pointer)
             (setf (cffi:mem-ref opp :pointer) op)
             (let ((status (%vips-cache-operation-buildp opp)))
               ;; buildp may swap OP for a cached equivalent (unref-ing the
               ;; original); track whatever it left behind so we unref that.
               (setf op (cffi:mem-ref opp :pointer))
               (unless (zerop status)
                 (raise-vips-error))
               (cond
                 (outputs
                  (let ((names (if (eq outputs :all) (%output-names op) outputs)))
                    (values-list
                     (mapcar (lambda (name) (%get-property op name)) names))))
                 ;; a normal output argument (default "out") is present
                 ((let ((flags (funcall flags-of output)))
                    (and flags (%arg-output-p flags)))
                  (%get-property op output))
                 ;; else fall back to the operation's first output argument
                 ((%output-names op)
                  (%get-property op (first (%output-names op))))
                 ;; else an in-place op: return the mutated MODIFY copy
                 (primary-modify
                  (setf returned primary-modify)
                  (wrap-image primary-modify))
                 (t (error 'vips-error
                           :message (format nil "operation ~s has no output"
                                            nickname)))))))
      ;; Release the operation and any MODIFY copies we did not hand back.
      (%g-object-unref op)
      (dolist (copy modify-copies)
        (unless (eq copy returned)
          (%g-object-unref copy))))))

;;; ---------------------------------------------------------------------------
;;; Thin named wrappers built on the engine
;;; ---------------------------------------------------------------------------

(defmacro define-operation (lisp-name nickname (&rest params) &body clauses)
  "Define LISP-NAME as a function over CALL-OPERATION for libvips NICKNAME.

PARAMS is an ordinary lambda list of Lisp parameters.  Each clause is
(ARG-NAME FORM), mapping a libvips argument name (a string) to a FORM that may
reference the parameters.  A leading docstring is allowed.

Example:
  (define-operation gamma \"gamma\" (image &key (exponent (/ 1.0d0 2.4d0)))
    \"Apply a gamma curve.\"
    (\"in\" image)
    (\"exponent\" (float exponent 1.0d0)))"
  (let ((docstring (when (stringp (first clauses)) (pop clauses))))
    `(defun ,lisp-name ,params
       ,@(when docstring (list docstring))
       (call-operation ,nickname
                       (list ,@(loop for (arg form) in clauses
                                     collect arg collect form))))))

;; A handful of operations we did NOT hand-bind, now available for free.

(define-operation image-abs "abs" (image)
  "Absolute value of IMAGE, pixelwise. Returns a new image."
  ("in" image))

(define-operation sign "sign" (image)
  "Unit vector in the direction of each pixel (-1, 0 or 1). Returns a new image."
  ("in" image))

(define-operation flatten "flatten" (image)
  "Flatten an image with an alpha channel against a background. Returns a new
image with the alpha removed."
  ("in" image))

(define-operation gamma "gamma" (image &key (exponent (/ 1.0d0 2.4d0)))
  "Apply a gamma curve with the given EXPONENT. Returns a new image."
  ("in" image)
  ("exponent" (float exponent 1.0d0)))

;; Phase 2: an operation whose argument is a VipsArrayDouble.
(define-operation affine "affine" (image matrix)
  "Apply the 2x2 affine transform MATRIX -- a list (a b c d) mapping output
coordinates back to input -- to IMAGE. Returns a new image."
  ("in" image)
  ("matrix" matrix))

;; Phase 3: an operation whose argument is a VipsArrayImage.
(define-operation arrayjoin "arrayjoin" (images &key (across 1))
  "Join a list of IMAGES into a grid, ACROSS images per row. Returns a new
image."
  ("in" images)
  ("across" across))

;;; ---------------------------------------------------------------------------
;;; Public introspection + auto-generated wrappers (Phase 4)
;;; ---------------------------------------------------------------------------

(defun operation-arguments (nickname)
  "Describe the arguments of libvips operation NICKNAME. Returns a list of
plists, one per argument, with keys :NAME (string), :INPUT, :OUTPUT,
:REQUIRED, :DEPRECATED (booleans) and :TYPE (the GValue kind keyword, e.g.
:DOUBLE, :ENUM, :OBJECT, or NIL if unknown)."
  (ensure-gtypes)
  (let ((op (%vips-operation-new nickname)))
    (when (cffi:null-pointer-p op)
      (raise-vips-error))
    (unwind-protect
         (loop for (name . flags) in (%object-arguments op)
               collect (list :name name
                             :input (%arg-input-p flags)
                             :output (%arg-output-p flags)
                             :required (%arg-required-p flags)
                             :deprecated (%arg-deprecated-p flags)
                             :type (ignore-errors
                                    (%gvalue-kind
                                     (%property-value-type op name)))))
      (%g-object-unref op))))

(defun operation-required-inputs (nickname)
  "The names of NICKNAME's required, non-deprecated input arguments, in
declaration order."
  (loop for a in (operation-arguments nickname)
        when (and (getf a :input) (getf a :required) (not (getf a :deprecated)))
          collect (getf a :name)))

(defun operation-optional-inputs (nickname)
  "The names of NICKNAME's optional, non-deprecated input arguments."
  (loop for a in (operation-arguments nickname)
        when (and (getf a :input) (not (getf a :required))
                  (not (getf a :deprecated)))
          collect (getf a :name)))

(defun operation-outputs (nickname)
  "The names of NICKNAME's non-deprecated output arguments."
  (loop for a in (operation-arguments nickname)
        when (and (getf a :output) (not (getf a :deprecated)))
          collect (getf a :name)))

(defun describe-operation (nickname &optional (stream *standard-output*))
  "Print a human-readable summary of NICKNAME's arguments to STREAM."
  (format stream "~&operation ~s~%" nickname)
  (dolist (a (operation-arguments nickname))
    ;; NB: use ~:[~;..~] (which consumes its flag) rather than ~@[..~] (which
    ;; leaves a non-nil flag for the next directive and would shift columns).
    (format stream "  ~14a ~7a ~10a~:[~;  (required)~]~:[~;  (deprecated)~]~%"
            (getf a :name)
            (cond ((getf a :input) "input") ((getf a :output) "output") (t "-"))
            (string-downcase (princ-to-string (or (getf a :type) "-")))
            (getf a :required)
            (getf a :deprecated)))
  (values))

(defun make-operation-caller (nickname)
  "Return a function implementing libvips NICKNAME, derived from its
introspected arguments. The function takes the required inputs as positional
arguments (in declared order) followed by &rest OPTIONS -- a plist of optional
argument names (strings) to values -- and returns the primary \"out\"."
  (let* ((required (operation-required-inputs nickname))
         (arity (length required)))
    (lambda (&rest call-args)
      (when (< (length call-args) arity)
        (error 'vips-error
               :message (format nil "~a requires ~d input~:p: ~{~a~^, ~}"
                                nickname arity required)))
      (let ((positional (subseq call-args 0 arity))
            (options (nthcdr arity call-args)))
        (call-operation nickname
                        (append (mapcan #'list required positional)
                                options))))))

(defmacro defvips (lisp-name &optional
                   (nickname (string-downcase (string lisp-name))))
  "Define LISP-NAME as an auto-generated wrapper for libvips NICKNAME (default:
the downcased name), introspecting the operation's arguments at load time.

The generated function takes the required inputs positionally, then a &rest
plist of optional arguments, and returns the primary output. Example:

  (defvips scale)                 ; scale pixel values to 0-255
  (scale img)                     ; => new image
  (scale img \"exp\" 0.5d0)         ; with an option"
  `(progn
     (setf (fdefinition ',lisp-name) (make-operation-caller ,nickname)
           (documentation ',lisp-name 'function)
           (format nil "Auto-generated wrapper for libvips operation ~s.~%~
                        Required inputs: ~{~a~^, ~}."
                   ,nickname (operation-required-inputs ,nickname)))
     ',lisp-name))

;;; ---------------------------------------------------------------------------
;;; Enumerating and bulk-generating operations
;;; ---------------------------------------------------------------------------

(defvar *operation-type-collector* nil
  "Accumulator used by the vips_type_map_all callback.")

(cffi:defcallback %collect-operation-type :pointer ((type gtype) (a :pointer))
  (declare (ignore a))
  (push type *operation-type-collector*)
  (cffi:null-pointer))                  ; NULL => keep iterating

(defun %abstract-type-p (type)
  (plusp (%g-type-test-flags type +g-type-flag-abstract+)))

(defun %all-operation-types ()
  "Every GType descending from VipsOperation (abstract and concrete)."
  (ensure-gtypes)
  (let ((*operation-type-collector* nil))
    (%vips-type-map-all (%g-type-from-name "VipsOperation")
                        (cffi:callback %collect-operation-type)
                        (cffi:null-pointer))
    (nreverse *operation-type-collector*)))

(defun %type-group (type)
  "The group of an operation TYPE: the nickname of its ancestor directly under
VipsOperation, but only when that ancestor is abstract (a real family such as
\"arithmetic\"). Operations registered directly under VipsOperation return NIL."
  (let ((base (%g-type-from-name "VipsOperation")))
    (loop for current = type then parent
          for parent = (%g-type-parent current)
          when (= parent base)
            do (return (when (%abstract-type-p current)
                         (%vips-nickname-find current)))
          when (zerop parent)
            do (return nil))))

(defun list-operations ()
  "Return the nicknames of all concrete (instantiable) libvips operations,
sorted."
  (sort (loop for type in (%all-operation-types)
              unless (%abstract-type-p type)
                collect (%vips-nickname-find type))
        #'string<))

(defun operation-groups ()
  "Return the names of libvips operation groups (families with an abstract base
class, e.g. \"arithmetic\", \"conversion\"), sorted."
  (sort (remove-duplicates
         (remove nil (loop for type in (%all-operation-types)
                           unless (%abstract-type-p type)
                             collect (%type-group type)))
         :test #'string=)
        #'string<))

(defun operations-in-group (group)
  "Return the nicknames of the concrete operations in GROUP (e.g.
\"arithmetic\"), sorted."
  (sort (loop for type in (%all-operation-types)
              unless (%abstract-type-p type)
                when (equal group (%type-group type))
                  collect (%vips-nickname-find type))
        #'string<))

(defun %lispify-name (string)
  "Turn a libvips nickname into a Lisp symbol name: underscores to hyphens,
upcased."
  (string-upcase (substitute #\- #\_ string)))

(defun defvips-all (&key group nicknames (prefix "") (package *package*)
                         (skip '()) verbose)
  "Bulk-define wrapper functions (as by DEFVIPS) for many libvips operations.

Choose the operations with exactly one of: GROUP (a group name such as
\"arithmetic\"), NICKNAMES (an explicit list), or neither (every operation).
Each wrapper is named PREFIX + nickname -- underscores turned to hyphens,
upcased -- interned in PACKAGE (default *PACKAGE*). Operations in SKIP, or
whose caller cannot be built, are skipped.

To avoid clobbering standard functions (e.g. an \"abs\" operation vs CL:ABS),
pass a PREFIX or a dedicated PACKAGE. Returns the list of symbols defined."
  (ensure-gtypes)
  (let ((names (cond (nicknames nicknames)
                     (group (operations-in-group group))
                     (t (list-operations))))
        (defined '()))
    (dolist (nick names (nreverse defined))
      (unless (member nick skip :test #'string=)
        (let ((symbol (intern (%lispify-name (concatenate 'string prefix nick))
                              package)))
          (when (ignore-errors
                  (setf (fdefinition symbol) (make-operation-caller nick)
                        (documentation symbol 'function)
                        (format nil "Auto-generated wrapper for libvips ~s."
                                nick))
                  t)
            (push symbol defined)
            (when verbose (format t "~&  ~s -> ~a~%" nick symbol))))))))
