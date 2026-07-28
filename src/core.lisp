;;;; core.lisp --- Library init/shutdown, versioning and error plumbing

(in-package #:vips)

;;; ---------------------------------------------------------------------------
;;; Raw foreign entry points
;;; ---------------------------------------------------------------------------

(cffi:defcfun ("vips_init" %vips-init) :int
  (argv0 :string))

(cffi:defcfun ("vips_shutdown" %vips-shutdown) :void)

(cffi:defcfun ("vips_version" %vips-version) :int
  (flag :int))

(cffi:defcfun ("vips_leak_set" %vips-leak-set) :void
  (leak :int))

(cffi:defcfun ("vips_error_buffer" %vips-error-buffer) :string)

(cffi:defcfun ("vips_error_clear" %vips-error-clear) :void)

;; glib helpers for freeing buffers / dropping GObject references.
(cffi:defcfun ("g_free" %g-free) :void
  (pointer :pointer))

(cffi:defcfun ("g_object_unref" %g-object-unref) :void
  (object :pointer))

;;; ---------------------------------------------------------------------------
;;; Error handling
;;; ---------------------------------------------------------------------------

(defun error-buffer ()
  "Return the current contents of the libvips error buffer as a string."
  (or (%vips-error-buffer) ""))

(defun clear-error ()
  "Clear the libvips error buffer."
  (%vips-error-clear))

(defun raise-vips-error ()
  "Signal a VIPS-ERROR carrying the current error buffer, then clear it."
  (let ((message (error-buffer)))
    (clear-error)
    (error 'vips-error :message message)))

;;; ---------------------------------------------------------------------------
;;; Lifecycle
;;; ---------------------------------------------------------------------------

(defvar *initialized* nil
  "T once VIPS_INIT has been called successfully.")

(defun initialized-p ()
  "Return T if libvips has been initialized in this image."
  (and *initialized* t))

;; vips_init is not reentrant, and lazy initialization can be reached from
;; several threads at once (libvips operations are otherwise thread-safe). Guard
;; the one-time setup with a lock.
#+sbcl (defvar *init-lock* (sb-thread:make-mutex :name "cl-vips-init"))

(defmacro with-init-lock (&body body)
  #+sbcl `(sb-thread:with-mutex (*init-lock*) ,@body)
  #-sbcl `(progn ,@body))

(defun init (&optional (argv0 "cl-vips"))
  "Load the foreign libraries and initialize libvips. Idempotent and
thread-safe: calling more than once, from any thread, is a no-op after the
first. ARGV0 is passed to vips_init for diagnostics. Signals VIPS-ERROR if
initialization fails."
  (with-init-lock
    (unless *initialized*
      (load-libraries)
      ;; libvips does IEEE arithmetic that legitimately produces NaN/inf; SBCL
      ;; enables floating-point traps by default, which turns those into
      ;; FLOATING-POINT-INVALID-OPERATION errors when control returns to Lisp.
      ;; Mask the traps so foreign math behaves as C expects.
      #+sbcl (sb-int:set-floating-point-modes :traps nil)
      (unless (zerop (%vips-init argv0))
        (raise-vips-error))
      (setf *initialized* t)))
  *initialized*)

(defun set-leak-checking (on)
  "Turn libvips leak checking on or off. When on, libvips tracks live objects
and prints any that remain -- e.g. images you forgot to UNREF -- to stderr at
SHUTDOWN. Intended as a development aid, since images are not freed by the GC.
Must be called after INIT."
  (ensure-init)
  (%vips-leak-set (if on 1 0))
  (and on t))

(defun shutdown ()
  "Shut libvips down and release its resources. After this, INIT must be
called again before further use."
  (when *initialized*
    (%vips-shutdown)
    (setf *initialized* nil))
  (values))

(defun ensure-init ()
  "Initialize libvips on demand."
  (unless *initialized* (init)))

;;; ---------------------------------------------------------------------------
;;; Versioning
;;; ---------------------------------------------------------------------------

(defun version ()
  "Return the libvips version as three values: MAJOR MINOR MICRO."
  (ensure-init)
  (values (%vips-version 0)
          (%vips-version 1)
          (%vips-version 2)))

(defun version-string ()
  "Return the libvips version as a dotted string, e.g. \"8.18.4\"."
  (multiple-value-bind (major minor micro) (version)
    (format nil "~d.~d.~d" major minor micro)))
