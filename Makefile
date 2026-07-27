# Makefile for cl-vips.
#
#   make build         -- build the ./cl-vips executable via ASDF program-op
#   make test          -- run the FiveAM test suite (nonzero exit on failure)
#   make tutorial      -- tangle TUTORIAL.org into tutorial.lisp
#   make tutorial-run  -- tangle and run the tutorial end to end
#   make clean         -- remove build artifacts
#
# Override tools with e.g.  make LISP=/path/to/sbcl EMACS=/path/to/emacs build

LISP  ?= sbcl
EMACS ?= emacs

# Bootstrap: load ASDF, load Quicklisp if present (to resolve cffi/fiveam),
# and register this directory so the cl-vips systems are found.
BOOT = --non-interactive \
  --eval '(require :asdf)' \
  --eval '(let ((q (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))) (when (probe-file q) (load q)))' \
  --eval '(push (uiop:getcwd) asdf:*central-registry*)'

.PHONY: build test tutorial tutorial-run clean

## build: dump ./cl-vips (next to cl-vips.asd) via asdf:make
build:
	$(LISP) $(BOOT) --eval '(asdf:make :cl-vips/executable)'

## test: load and run the suite; exit nonzero if any check fails
test:
	$(LISP) $(BOOT) \
	  --eval '(asdf:load-system :cl-vips/test)' \
	  --eval '(uiop:quit (if (uiop:symbol-call :vips/test :run-tests) 0 1))'

## tutorial: tangle TUTORIAL.org into a runnable tutorial.lisp
tutorial: tutorial.lisp
tutorial.lisp: TUTORIAL.org
	$(EMACS) --batch -l org $< -f org-babel-tangle

## tutorial-run: tangle and then execute the tutorial end to end
tutorial-run: tutorial.lisp
	$(LISP) --non-interactive --load tutorial.lisp

## clean: remove the executable, tangled tutorial and any stray fasls
clean:
	rm -f cl-vips tutorial.lisp
	find . -name '*.fasl' -delete
