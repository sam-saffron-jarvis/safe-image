# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../lib/safe_image"

FIXTURES = File.expand_path("fixtures/images", __dir__)
PROFILE = File.expand_path("../lib/safe_image/RT_sRGB.icm", __dir__)
JPG = File.join(FIXTURES, "huge.jpg")
PNG = File.join(FIXTURES, "large_and_unoptimized.png")

def assert_pixel_equal!(expected, actual, name)
  _stdout, stderr, _status = Open3.capture3("compare", "-metric", "AE", expected, actual, "null:")
  metric = stderr.strip
  abort "#{name}: expected pixel parity, got AE #{metric}" unless metric == "0" || metric == "0 (0)"
end

CONVERT = SafeImage::ImageMagickBackend.convert_command

Dir.mktmpdir do |dir|
  expected = File.join(dir, "disc-resize.jpg")
  actual = File.join(dir, "gem-resize.jpg")
  system(
    CONVERT, "jpeg:#{JPG}[0]", "-auto-orient", "-gravity", "center", "-background", "transparent",
    "-thumbnail", "600x400^", "-extent", "600x400", "-interpolate", "catrom",
    "-unsharp", "2x0.5+0.7+0", "-interlace", "none", "-profile", PROFILE, expected,
    exception: true
  )
  SafeImage.resize(JPG, actual, 600, 400, optimize: false)
  assert_pixel_equal!(expected, actual, "resize")

  expected = File.join(dir, "disc-crop.jpg")
  actual = File.join(dir, "gem-crop.jpg")
  system(
    CONVERT, "jpeg:#{JPG}[0]", "-auto-orient", "-gravity", "north", "-background", "transparent",
    "-thumbnail", "400x400^", "-crop", "400x400+0+0", "-unsharp", "2x0.5+0.7+0",
    "-interlace", "none", "-profile", PROFILE, expected,
    exception: true
  )
  SafeImage.crop(JPG, actual, 400, 400, optimize: false)
  assert_pixel_equal!(expected, actual, "crop")

  expected = File.join(dir, "disc-down.png")
  actual = File.join(dir, "gem-down.png")
  system(
    CONVERT, "png:#{PNG}[0]", "-auto-orient", "-gravity", "center", "-background", "transparent",
    "-interlace", "none", "-resize", "50%", "-profile", PROFILE, expected,
    exception: true
  )
  SafeImage.downsize(PNG, actual, "50%", backend: :imagemagick, optimize: false)
  assert_pixel_equal!(expected, actual, "downsize")

  puts "OK ImageMagick compatibility parity"
end
