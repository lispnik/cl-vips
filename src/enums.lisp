;;;; enums.lisp --- libvips enumerated types

(in-package #:vips)

;;; VipsBandFormat --- the pixel storage format of a band.
(cffi:defcenum band-format
  (:notset -1)
  (:uchar 0)
  (:char 1)
  (:ushort 2)
  (:short 3)
  (:uint 4)
  (:int 5)
  (:float 6)
  (:complex 7)
  (:double 8)
  (:dpcomplex 9))

;;; VipsInterpretation --- how the bands should be interpreted (colour space).
(cffi:defcenum interpretation-enum
  (:error -1)
  (:multiband 0)
  (:b-w 1)
  (:histogram 10)
  (:xyz 12)
  (:lab 13)
  (:cmyk 15)
  (:labq 16)
  (:rgb 17)
  (:cmc 18)
  (:lch 19)
  (:labs 21)
  (:srgb 22)
  (:yxy 23)
  (:fourier 24)
  (:rgb16 25)
  (:grey16 26)
  (:matrix 27)
  (:scrgb 28)
  (:hsv 29))

;;; VipsDirection --- flip axis.
(cffi:defcenum direction-enum
  (:horizontal 0)
  (:vertical 1))

;;; VipsAngle --- fixed rotation angles.
(cffi:defcenum angle-enum
  (:d0 0)
  (:d90 1)
  (:d180 2)
  (:d270 3))

;;; VipsExtend --- how to fill new pixels when embedding / extending.
(cffi:defcenum extend-enum
  (:black 0)
  (:copy 1)
  (:repeat 2)
  (:mirror 3)
  (:white 4)
  (:background 5))
