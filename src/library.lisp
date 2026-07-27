;;;; library.lisp --- Foreign library definitions and loading

(in-package #:vips)

(defvar *library-directories*
  '(#+darwin #p"/opt/homebrew/lib/"
    #+darwin #p"/usr/local/lib/"
    #-darwin #p"/usr/lib/"
    #-darwin #p"/usr/local/lib/")
  "Extra directories searched for the libvips / glib shared libraries.
Pushed onto CFFI:*FOREIGN-LIBRARY-DIRECTORIES* by LOAD-LIBRARIES.")

;; glib / gobject supply g_free and g_object_unref used for memory
;; management of libvips return buffers and image objects.
(cffi:define-foreign-library libglib
  (:darwin (:or "libglib-2.0.0.dylib" "libglib-2.0.dylib"))
  (:unix (:or "libglib-2.0.so.0" "libglib-2.0.so"))
  (t (:default "libglib-2.0")))

(cffi:define-foreign-library libgobject
  (:darwin (:or "libgobject-2.0.0.dylib" "libgobject-2.0.dylib"))
  (:unix (:or "libgobject-2.0.so.0" "libgobject-2.0.so"))
  (t (:default "libgobject-2.0")))

(cffi:define-foreign-library libvips
  (:darwin (:or "libvips.42.dylib" "libvips.dylib"))
  (:unix (:or "libvips.so.42" "libvips.so"))
  (t (:default "libvips")))

(defvar *libraries-loaded* nil)

(defun load-libraries ()
  "Ensure the required foreign libraries are loaded. Idempotent."
  (unless *libraries-loaded*
    (dolist (dir *library-directories*)
      (when (and dir (probe-file dir))
        (pushnew dir cffi:*foreign-library-directories* :test #'equal)))
    (cffi:use-foreign-library libglib)
    (cffi:use-foreign-library libgobject)
    (cffi:use-foreign-library libvips)
    (setf *libraries-loaded* t))
  *libraries-loaded*)
