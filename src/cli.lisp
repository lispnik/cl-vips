;;;; cli.lisp --- A command-line driver for cl-vips
;;;;
;;;; Mirrors the spirit of the `vips' CLI: dispatch any libvips operation by
;;;; nickname, plus a few helper subcommands built on the introspection layer.

(defpackage #:vips-cli
  (:use #:cl)
  (:export #:main #:toplevel))

(in-package #:vips-cli)

(defparameter *program* "cl-vips")

;;; ---------------------------------------------------------------------------
;;; Argument-value parsing
;;; ---------------------------------------------------------------------------

(defun split-on (string char)
  (loop with start = 0
        for pos = (position char string :start start)
        collect (subseq string start pos)
        while pos do (setf start (1+ pos))))

(defun numeric-looking-p (string)
  (and (plusp (length string))
       (some #'digit-char-p string)
       (every (lambda (c)
                (or (digit-char-p c)
                    (member c '(#\- #\+ #\. #\e #\E #\d #\D #\/))))
              string)))

(defun parse-scalar (string)
  "Turn a CLI token into a Lisp value: integers/floats become numbers,
true/false become booleans, a leading @ means \"load this file as an image\"
(a marker resolved later), everything else stays a string (which covers enum
nicknames and filenames)."
  (cond ((and (plusp (length string)) (char= (char string 0) #\@))
         (cons :image-file (subseq string 1)))
        ((string-equal string "true") t)
        ((string-equal string "false") nil)
        ((numeric-looking-p string)
         (let ((*read-default-float-format* 'double-float))
           (let ((value (ignore-errors (read-from-string string))))
             (if (numberp value) value string))))
        (t string)))

(defun parse-value (string)
  "Like PARSE-SCALAR, but a comma-separated token becomes a list (an array
argument, e.g. a=1,2,3)."
  (if (find #\, string)
      (mapcar #'parse-scalar (split-on string #\,))
      (parse-scalar string)))

(defun option-token-p (token)
  (find #\= token))

(defun parse-options (tokens)
  "Turn (\"sigma=3\" \"centre=true\") into (\"sigma\" 3 \"centre\" t)."
  (loop for token in tokens
        for eq = (position #\= token)
        append (list (subseq token 0 eq)
                     (parse-value (subseq token (1+ eq))))))

;;; ---------------------------------------------------------------------------
;;; Subcommands
;;; ---------------------------------------------------------------------------

(defun cmd-version ()
  (format t "libvips ~a~%" (vips:version-string)))

(defun cmd-info (args)
  (let ((file (first args)))
    (unless file (error "info: expected a file argument"))
    (vips:with-image (img (vips:load-image file))
      (format t "file           : ~a~%" file)
      (format t "width          : ~d~%" (vips:width img))
      (format t "height         : ~d~%" (vips:height img))
      (format t "bands          : ~d~%" (vips:bands img))
      (format t "format         : ~a~%" (vips:image-format img))
      (format t "interpretation : ~a~%" (vips:interpretation img)))))

(defun cmd-groups ()
  (dolist (group (vips:operation-groups))
    (format t "~a~%" group)))

(defun cmd-list (args)
  (let ((nicknames (if (first args)
                       (vips:operations-in-group (first args))
                       (vips:list-operations))))
    (dolist (nickname nicknames)
      (format t "~a~%" nickname))))

(defun cmd-describe (args)
  (let ((op (first args)))
    (unless op (error "describe: expected an operation name"))
    (vips:describe-operation op)))

(defun cmd-run (args)
  "run <op> [infile] [outfile] [name=value ...]

INFILE is loaded into the operation's primary image input (whatever it is
named -- \"in\", \"image\", \"base\", ...); use - to read from stdin.  For a
creator that takes no input image (e.g. black), the first positional is the
output instead.  OUTFILE receives the result image, or -.EXT writes it to
stdout in that format; a scalar result is printed.  Image-valued options use
@FILE, e.g. overlay=@over.png, or a=@a.png,b=@b.png for an image array."
  (let* ((op (first args))
         (rest (rest args))
         (positionals (remove-if #'option-token-p rest))
         (raw-options (parse-options (remove-if-not #'option-token-p rest))))
    (unless op (error "run: expected an operation name"))
    (vips:with-image-pool
      (let* ((in-arg (primary-image-input op))
             (options (resolve-options raw-options))
             (inputs (if in-arg
                         (let ((infile (first positionals)))
                           (unless infile
                             (error "~a needs an input file (use - for stdin)" op))
                           (list* in-arg (load-input infile) options))
                         options))
             (outfile (if in-arg (second positionals) (first positionals)))
             (result (vips:call-operation op inputs)))
        (write-result op result outfile)))))

(defun primary-image-input (op)
  "The name of OP's first required, non-deprecated image (object) input, or
NIL if it has none (a creator)."
  (loop for a in (vips:operation-arguments op)
        when (and (getf a :input) (getf a :required)
                  (not (getf a :deprecated)) (eq (getf a :type) :object))
          return (getf a :name)))

(defun resolve-value (value)
  "Replace @FILE markers with loaded images (recursing into lists)."
  (cond ((and (consp value) (eq (car value) :image-file))
         (vips:load-image (cdr value)))
        ((and (consp value)
              (some (lambda (x) (and (consp x) (eq (car x) :image-file))) value))
         (mapcar #'resolve-value value))
        (t value)))

(defun resolve-options (options)
  (loop for (name value) on options by #'cddr
        collect name collect (resolve-value value)))

(defun load-input (infile)
  (if (string= infile "-")
      (vips:load-image-from-stream (binary-stdin))
      (vips:load-image infile)))

(defun stdout-suffix (outfile)
  "If OUTFILE is \"-.EXT\" (stdout with a format), return \".EXT\"; else NIL."
  (when (and (>= (length outfile) 2)
             (char= (char outfile 0) #\-)
             (char= (char outfile 1) #\.))
    (subseq outfile 1)))

(defun write-result (op result outfile)
  (cond
    ((vips:imagep result)
     (let ((suffix (and outfile (stdout-suffix outfile))))
       (cond
         (suffix
          (let ((out (binary-stdout)))
            (vips:save-image-to-stream result suffix out)
            (finish-output out)))
         ((and outfile (string= outfile "-"))
          (error "writing to stdout needs a format: use -.png, -.jpg, ..."))
         (outfile
          (vips:save-image result outfile)
          (format t "wrote ~a (~dx~d)~%"
                  outfile (vips:width result) (vips:height result)))
         (t (error "~a produces an image -- give an output file (or -.EXT for stdout)"
                   op)))))
    (t (format t "~a~%" result))))

(defun binary-stdin ()
  #+sbcl (sb-sys:make-fd-stream 0 :input t :element-type '(unsigned-byte 8)
                                 :name "stdin")
  #+ecl (ext:make-stream-from-fd 0 :input :element-type '(unsigned-byte 8))
  #-(or sbcl ecl) (error "reading images from stdin is not supported on this Lisp"))

(defun binary-stdout ()
  #+sbcl (sb-sys:make-fd-stream 1 :output t :element-type '(unsigned-byte 8)
                                 :name "stdout")
  #+ecl (ext:make-stream-from-fd 1 :output :element-type '(unsigned-byte 8))
  #-(or sbcl ecl) (error "writing images to stdout is not supported on this Lisp"))

(defparameter *usage*
  "cl-vips -- a command-line driver for libvips

Usage:
  cl-vips <operation> <in> [out] [name=value ...]   run an operation
  cl-vips run <operation> <in> [out] [name=value ...]
  cl-vips info <file>                               print image header
  cl-vips list [group]                              list operations
  cl-vips groups                                    list operation groups
  cl-vips describe <operation>                      show an operation's args
  cl-vips version                                   print the libvips version
  cl-vips help                                      this message

Examples:
  cl-vips info photo.jpg
  cl-vips gaussblur photo.jpg blur.png sigma=3
  cl-vips resize photo.jpg small.png scale=0.5
  cl-vips flip photo.jpg flipped.png direction=horizontal
  cl-vips describe gaussblur
")

(defun print-usage (&optional (stream *standard-output*))
  (write-string *usage* stream))

;;; ---------------------------------------------------------------------------
;;; Dispatch and entry points
;;; ---------------------------------------------------------------------------

(defun dispatch (args)
  (let ((command (first args))
        (rest (rest args)))
    (cond
      ((or (null command)
           (member command '("-h" "--help" "help") :test #'string=))
       (print-usage))
      ((string= command "version") (cmd-version))
      ((string= command "info")     (cmd-info rest))
      ((string= command "list")     (cmd-list rest))
      ((string= command "groups")   (cmd-groups))
      ((string= command "describe") (cmd-describe rest))
      ((string= command "run")      (cmd-run rest))
      ;; otherwise: treat the first token as an operation nickname
      (t (cmd-run args)))))

(defun cli-args ()
  "The user's command-line arguments, portably across implementations."
  (uiop:command-line-arguments))

(defun main (&optional (args (cli-args)))
  "Run the CLI over ARGS. Returns a Unix exit code (0 ok, 1 on error)."
  (handler-case
      (progn
        (vips:init)
        (dispatch args)
        (finish-output)
        0)
    (vips:vips-error (e)
      (format *error-output* "~a: ~a~%" *program* (vips:vips-error-message e))
      1)
    (error (e)
      (format *error-output* "~a: ~a~%" *program* e)
      1)))

(defun toplevel ()
  "Entry point for a saved executable."
  (uiop:quit (main)))
