;;;; conditions.lisp --- Error conditions

(in-package #:vips)

(define-condition vips-error (error)
  ((message :initarg :message :reader vips-error-message :initform ""))
  (:report (lambda (condition stream)
             (format stream "libvips error: ~a"
                     (vips-error-message condition))))
  (:documentation "Signalled when a libvips operation fails. The MESSAGE
slot carries the contents of the libvips error buffer at the time of
failure."))
