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
true/false become booleans, everything else stays a string (which covers enum
nicknames and filenames)."
  (cond ((string-equal string "true") t)
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
  "run <op> <infile> [outfile] [name=value ...]

Load INFILE as the \"in\" argument, run OP with any NAME=VALUE options, and
either save the resulting image to OUTFILE or print a scalar result."
  (let* ((op (first args))
         (rest (rest args))
         (positionals (remove-if #'option-token-p rest))
         (options (parse-options (remove-if-not #'option-token-p rest)))
         (infile (first positionals))
         (outfile (second positionals)))
    (unless op (error "run: expected an operation name"))
    (unless infile (error "run: expected an input file"))
    (vips:with-image-pool
      (let* ((in (vips:load-image infile))
             (result (vips:call-operation op (list* "in" in options))))
        (cond ((vips:imagep result)
               (unless outfile
                 (error "~a produces an image -- give an output file" op))
               (vips:save-image result outfile)
               (format t "wrote ~a (~dx~d)~%"
                       outfile (vips:width result) (vips:height result)))
              (t
               (format t "~a~%" result)))))))

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
  "The user's arguments, both when run as a saved executable and under
`sbcl --script'."
  (rest sb-ext:*posix-argv*))

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
  (sb-ext:exit :code (main)))
