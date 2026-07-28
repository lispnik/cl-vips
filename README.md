# cl-vips

[![CI](https://github.com/lispnik/cl-vips/actions/workflows/ci.yml/badge.svg)](https://github.com/lispnik/cl-vips/actions/workflows/ci.yml)

Common Lisp CFFI bindings to [libvips](https://www.libvips.org/), a fast,
low-memory image-processing library.

Tested with **SBCL** and **ECL** + **libvips 8.15+** on Linux and macOS, using
**CFFI** for the FFI and **FiveAM** for the test suite. CI runs the full suite
on `ubuntu-latest` and `macos-latest` under SBCL, plus a smoke test under ECL.

## Requirements

- SBCL or ECL
- Quicklisp (for `cffi` and `bordeaux-threads`, and `fiveam` for the tests)
- libvips and its glib/gobject dependencies on the shared-library search path
  - macOS: `brew install vips`
  - Debian/Ubuntu: `apt install libvips42`

`src/library.lisp` adds `/opt/homebrew/lib` and `/usr/local/lib` to CFFI's
search path automatically; adjust `vips:*library-directories*` if yours differ.

## Loading

```lisp
(push #p"/path/to/vips/" asdf:*central-registry*)
(ql:quickload :cl-vips)
(vips:init)                 ; call once before use
```

## Quick tour

```lisp
;; Load, transform, save. save-image / load-image take an optional libvips
;; option string (e.g. JPEG quality, PNG compression, access hints).
(vips:with-image (img (vips:load-image "photo.jpg"))
  (vips:with-image (small (vips:resize img 0.25))
    (vips:with-image (blurred (vips:gaussblur small 3.0))
      (vips:save-image blurred "thumb.jpg" :options "Q=85,strip"))))

;; Build an image from raw pixels -- no file needed.
(vips:with-image (img (vips:image-from-pixels
                       (make-array 12 :element-type '(unsigned-byte 8)
                                      :initial-element 128)
                       2 2 3))                       ; width height bands
  (list (vips:width img) (vips:height img)           ; => (2 2)
        (vips:getpoint img 0 0)))                    ; => (128.0d0 128.0d0 128.0d0)

;; Statistics.
(vips:with-image (img (vips:load-image "photo.jpg"))
  (values (vips:avg img) (vips:image-min img) (vips:image-max img)))

;; In-memory encode/decode round trip.
(vips:with-image (img (vips:black 64 64 :bands 3))
  (let ((png-bytes (vips:write-to-octets img ".png")))
    (vips:with-image (decoded (vips:image-from-octets png-bytes))
      (vips:width decoded))))                        ; => 64
```

## API summary

| Area | Functions |
|------|-----------|
| Lifecycle | `init` `shutdown` `initialized-p` `version` `version-string` `set-leak-checking` |
| Images | `image` `imagep` `image-live-p` `unref` `with-image` `with-images` `with-image-pool` `keep` |
| I/O | `load-image` `save-image` `image-from-octets` `write-to-octets` `image-from-pixels` |
| Streaming | `load-image-from-stream` `save-image-to-stream` |
| Raw pixels | `write-to-memory` `image-to-array` `image-from-array` |
| Introspection | `width` `height` `bands` `image-format` `interpretation` `filename` `get-double` `get-int` `get-string` `getpoint` |
| Metadata | `set-int` `set-double` `set-string` `set-blob` `get-blob` `remove-field` `get-fields` |
| Create | `black` |
| Geometry | `resize` `crop` `embed` `flip` `rotate` |
| Pixel/colour | `invert` `linear` `gaussblur` `colourspace` `cast` |
| Bands | `extract-band` `bandjoin` |
| Arithmetic | `add` `subtract` `multiply` |
| Statistics | `avg` `image-min` `image-max` `deviate` |
| Generic engine | `call-operation` `define-operation` `image-abs` `sign` `flatten` `gamma` `affine` `arrayjoin` |
| Introspection | `operation-arguments` `operation-required-inputs` `operation-optional-inputs` `operation-outputs` `describe-operation` `defvips` `make-operation-caller` |
| Enumeration | `list-operations` `operation-groups` `operations-in-group` `defvips-all` |
| Errors | `vips-error` `vips-error-message` |

## Calling any operation: the generic engine

The hand-written functions above cover a curated core. For everything else,
`call-operation` drives libvips's generic `VipsOperation` API — it can invoke
**any** operation by nickname, the way `pyvips` does:

```lisp
;; call-operation NICKNAME PLIST &key (output "out")
;; Inputs are a plist of libvips argument names -> Lisp values.

;; image in, image out
(vips:with-image (img (vips:load-image "photo.jpg"))
  (vips:with-image (out (vips:call-operation "gaussblur" (list "in" img "sigma" 3.0d0)))
    (vips:save-image out "blur.png")))

;; scalar output is returned as a number
(vips:call-operation "avg" (list "in" some-image))        ; => 128.0d0

;; enums are passed as keywords
(vips:call-operation "flip" (list "in" img "direction" :horizontal))
```

Values are boxed/unboxed by querying each argument's declared GType, so you
pass natural Lisp values: numbers, `t`/`nil`, strings, enum keywords, and
`vips:image` objects. Object outputs come back as owned `vips:image`s.

In-place (`MODIFY`) operations work too — the `draw` family (`draw_circle`,
`draw_line`, `draw_image`, …) mutate their input, so the engine draws on a
private memory copy and returns it, leaving your image untouched:

```lisp
(vips:call-operation "draw_circle"
                     (list "image" img "ink" '(255 0 0) "cx" 50 "cy" 50 "radius" 20))
```

Define a tidy named wrapper over any operation with `define-operation`:

```lisp
(vips:define-operation sharpen "sharpen" (image &key (sigma 1.0))
  "Sharpen IMAGE."
  ("in" image)
  ("sigma" (float sigma 1.0d0)))
```

Array arguments work too — pass a list (or a lone number, which is promoted to
a one-element array):

```lisp
;; per-band  out = a*in + b
(vips:call-operation "linear" (list "in" img "a" '(2.0 1.0 0.0) "b" '(0.0 10.0 5.0)))

;; a 2x2 affine transform (VipsArrayDouble), via the AFFINE wrapper
(vips:affine img '(1.0 0.0 0.0 1.0))

;; array-valued output is returned as a list
(vips:call-operation "getpoint" (list "in" img "x" 0 "y" 0) :output "out_array")
```

**Engine scope.**

- *Phase 1* — boolean, int, uint, int64, uint64, float, double, string, enum,
  flags and object (image) arguments.
- *Phase 2* (done) — `VipsArrayInt` and `VipsArrayDouble`, in both directions,
  with scalar→array promotion. Unlocks per-band `linear`, `affine`,
  convolution/recomb matrices, multi-value backgrounds, and array-valued
  outputs like `getpoint`.
- *Phase 3* (done) — `VipsArrayImage` and `VipsBlob`, in both directions, with
  correct reference counting on image arrays. Unlocks `arrayjoin`/`composite`,
  buffer loaders like `pngload_buffer`, and ICC-profile blobs (`profile_load`).
- *Phase 4* (done) — argument introspection via `vips_object_get_args`:
  required/optional-input and output discovery, multi-output operations,
  `defvips` (auto-generate one wrapper from an operation's signature), and
  operation enumeration/grouping via the type system with `defvips-all` to
  bulk-generate wrappers for a whole group.

### Introspection and multi-output

```lisp
(vips:operation-required-inputs "gaussblur")   ; => ("in" "sigma")
(vips:operation-outputs "min")                 ; => ("out" "x" "y" ...)
(vips:describe-operation "flip")               ; prints an argument summary

;; operations with several outputs return multiple values
(vips:call-operation "min" (list "in" img) :outputs '("out" "x" "y"))
;; => 0.0d0, 0, 0   (minimum value and its position)
```

### Auto-generating a wrapper

`defvips` introspects an operation and defines a function whose required inputs
are positional and whose optional arguments are a trailing plist — no
hand-written binding needed:

```lisp
(vips:defvips scale)              ; libvips "scale": stretch pixels to 0..255
(scale img)                       ; => new image
(scale img "exp" 0.5d0)           ; with an option
```

### Enumerating and bulk-generating

libvips operations are enumerated (and grouped by their class family) directly
from the type system, so wrappers for a whole group can be minted at once:

```lisp
(vips:operation-groups)                  ; => ("arithmetic" "colour" "conversion" ...)
(vips:operations-in-group "arithmetic")  ; => ("abs" "add" "boolean" ...)
(vips:list-operations)                   ; => every operation nickname

;; define op-abs, op-add, op-invert, ... in this package
(vips:defvips-all :group "arithmetic" :prefix "op-")
(op-invert img)
```

Pass a `:prefix` or dedicated `:package` so generated names (e.g. an `abs`
operation) don't collide with `cl:abs` and friends.

## Memory management

A `vips:image` wraps a libvips `VipsImage` (a GObject). **Ownership is explicit
and deterministic — images are never freed by the garbage collector.** A
libvips image can pin a large foreign pixel buffer the Lisp GC can neither see
nor account for, so relying on collection timing would let C memory grow
unbounded. You free an image in one of these ways:

```lisp
;; 1. scoped — freed on exit, even on non-local exit (preferred)
(vips:with-image (img (vips:load-image "photo.jpg"))
  ... )
(vips:with-images ((a (vips:black 8 8)) (b (vips:black 4 4)))
  ... )

;; 2. explicit
(let ((img (vips:black 8 8)))
  ... (vips:unref img))          ; idempotent

;; 3. a pool — frees every image created in its extent; good for loops
(vips:with-image-pool
  (dotimes (i 100)
    (process (vips:black 16 16))))   ; all 100 (and derivatives) freed on exit
```

Every operation returns a **new** image you own; inputs are never mutated or
freed. Using an image after it is freed signals a Lisp error rather than
crashing.

To carry a result out of a pool, detach it with `keep`:

```lisp
(let ((result (vips:with-image-pool
                (vips:keep (final-step (intermediate ...))))))
  ... (vips:unref result))
```

Because nothing is auto-freed, a dropped image simply leaks. During development
call `(vips:set-leak-checking t)` — libvips will then print any objects still
alive (images you forgot to free) at `shutdown`.

**Threads.** `vips:init` is thread-safe (the one-time setup is lock-guarded, and
it can be reached lazily from any thread); libvips operations are themselves
thread-safe, so images can be processed concurrently. An individual `image`
wrapper, like most objects, should not be mutated from two threads at once.

## Raw pixel data

Beyond one-pixel `getpoint`, you can move whole images to and from Lisp arrays:

```lisp
;; image -> a (HEIGHT WIDTH BANDS) array, element type matching the format
(vips:image-to-array img)          ; e.g. (unsigned-byte 8) for :uchar, single-float for :float

;; a Lisp array -> image (format inferred from the element type; rank 2 = 1 band)
(vips:image-from-array pixels)

;; the raw interleaved bytes plus geometry
(vips:write-to-memory img)         ; => (values octets width height bands format)
```

`image-to-array` / `image-from-array` round-trip exactly, including non-uchar
formats (`:ushort`, `:float`, `:double`, …).

## Metadata

Beyond reading fields (`get-int`/`get-double`/`get-string`), you can set,
remove and list them:

```lisp
(vips:set-string img "exif-ifd0-ImageDescription" "sunset")
(vips:set-int img "orientation" 6)
(vips:get-fields img)               ; => ("width" "height" ... "orientation")
(vips:remove-field img "orientation")
(vips:set-blob img "my-profile" icc-bytes)   ; and (vips:get-blob img "my-profile")
```

These mutate the image's metadata in place (pixels untouched); set them on
images you own.

## Streaming

Load from or save to any binary stream — a file, socket, or in-memory stream —
without a filename, via libvips custom sources/targets:

```lisp
;; save through a stream
(with-open-file (out "photo.png" :direction :output
                                 :element-type '(unsigned-byte 8) :if-exists :supersede)
  (vips:save-image-to-stream img ".png" out))

;; load through a stream (keep it open until the image is freed)
(with-open-file (in "photo.jpg" :element-type '(unsigned-byte 8))
  (vips:with-image (img (vips:load-image-from-stream in))
    (vips:width img)))
```

The stream must have element type `(unsigned-byte 8)`. Seekable streams (files)
support the full range of loaders; non-seekable ones (sockets, pipes) work with
formats libvips can read sequentially.

## Command-line driver

`cl-vips/cli` provides a command-line tool that mirrors the `vips` CLI: it
dispatches any libvips operation by nickname, plus helper subcommands built on
the introspection layer.

Build a standalone executable with `make` (which runs ASDF's `program-op` — the
`cl-vips/executable` system declares it as its build operation, dumping
`./cl-vips` next to `cl-vips.asd`):

```sh
make build      # equivalently: asdf:make :cl-vips/executable

./cl-vips version
./cl-vips info photo.jpg
./cl-vips gaussblur photo.jpg blur.png sigma=3
./cl-vips resize photo.jpg small.png scale=0.5
./cl-vips flip photo.jpg flipped.png direction=horizontal
./cl-vips describe gaussblur
./cl-vips list arithmetic
./cl-vips groups
```

libvips is loaded lazily at run time (by `vips:init`), so it is not baked into
the image and the executable stays portable.

- The first token is an operation nickname (or a subcommand: `info`, `list`,
  `groups`, `describe`, `version`, `run`, `help`).
- The input file is loaded into the operation's **primary image input**,
  whatever it is named (`in`, `image`, `base`, …) — so draw ops work too:
  `./cl-vips draw_circle in.png out.png ink=255,0,0 cx=50 cy=50 radius=20`.
  A creator with no image input (e.g. `black`) instead takes the output as its
  first positional: `./cl-vips black out.png width=64 height=64 bands=3`.
- The output file receives the result; a scalar result (e.g. `avg`) is printed.
- Use `-` for **stdin** and `-.EXT` for **stdout**, so the driver composes in
  pipelines: `./cl-vips invert - -.png < in.png > out.png`.
- Extra options are `name=value` pairs. Values parse as booleans, integers,
  floats, comma-lists (`a=1,2,3` → an array), enum nicknames
  (`direction=horizontal`), or **`@FILE` to load another image**
  (`./cl-vips composite2 base.png out.png overlay=@over.png mode=over`).

To iterate without building, load the CLI system in a REPL and call the driver
directly — it is just a function, `vips-cli:main`, taking a list of argument
strings and returning an exit code:

```lisp
(asdf:load-system :cl-vips/cli)
(vips-cli:main '("info" "photo.jpg"))
```

## Running the tests

```sh
make test        # exits nonzero if any check fails
```

or from a REPL:

```lisp
(ql:quickload :cl-vips/test)
(asdf:test-system :cl-vips)      ; or (vips/test:run-tests)
```

The suite (272 checks across core, I/O, operations, the generic engine, the
command-line driver and error handling) builds its fixtures from raw memory and
programmatic ramps, so it needs **no sample image files**.

## Make targets

| Target | Does |
|--------|------|
| `make build` | dump the `./cl-vips` executable via ASDF `program-op` |
| `make test` | run the test suite (nonzero exit on failure) |
| `make tutorial` | tangle `TUTORIAL.org` into `tutorial.lisp` (needs Emacs) |
| `make tutorial-run` | tangle and run the tutorial end to end |
| `make clean` | remove the executable, tangled tutorial and stray fasls |

## Implementation notes

### Variadic ABI (important)

Almost every libvips operation is a C-variadic function: fixed arguments
followed by optional `name, value, …, NULL` pairs. These are called through
`cffi:foreign-funcall-varargs`, **not** plain `cffi:foreign-funcall`, so the
fixed/variadic boundary is marked. This matters on the **Apple arm64** ABI,
where variadic arguments are passed on the stack while fixed ones go in
registers — a plain call mis-passes the `NULL` terminator and options, and
libvips reports spurious errors like `no property named 'E'` (or crashes).

### Lazy buffers

`vips_image_new_from_buffer` references its input buffer lazily instead of
copying it. `image-from-octets` therefore allocates the encoded bytes with
`foreign-alloc` and frees them through the image's cleanup thunk, so the buffer
outlives the image. `image-from-pixels` uses `..._new_from_memory_copy`, which
copies, so no such bookkeeping is needed.

## Why hand-written bindings? (GObject Introspection)

Because libvips is GObject-based it ships **GObject Introspection** data
(`Vips-8.0.typelib` / `.gir`), so GIR-consuming languages (Python via
PyGObject, Ruby, GJS, …) can bind it dynamically. The official Python binding,
`pyvips`, can run either over `gi` or over CFFI.

This library offers both approaches. The hand-written functions are small,
documented Lisp wrappers with clear error handling for the common core. On top
of that, the **generic engine** (`call-operation`, see above) drives libvips's
`VipsOperation` API by name to reach operations that aren't hand-bound — the
same technique `pyvips` uses — so coverage grows by adding GValue *types*
(Phases 2–4) rather than one binding per operation.

## License

LGPL-2.1-or-later, matching [libvips](https://github.com/libvips/libvips)
itself. See [`LICENSE`](LICENSE).
