# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/discourse_image_processing"

FIXTURES = "/home/agent/source/discourse/spec/fixtures/images"
JPG = File.join(FIXTURES, "huge.jpg")
PNG = File.join(FIXTURES, "large_and_unoptimized.png")
HEIC = File.join(FIXTURES, "should_be_jpeg.heic")
ICO = File.join(FIXTURES, "smallest.ico")

CASES = [
  [:thumbnail_vips, ->(d) { DiscourseImageProcessing.thumbnail(input: JPG, output: File.join(d, "thumb-vips.jpg"), width: 600, height: 400, backend: :vips, optimize: true, max_pixels: 100_000_000) }, [600, 400, "jpg"]],
  [:thumbnail_imagemagick, ->(d) { DiscourseImageProcessing.thumbnail(input: JPG, output: File.join(d, "thumb-im.jpg"), width: 600, height: 400, backend: :imagemagick, optimize: true, max_pixels: 100_000_000) }, [600, 400, "jpg"]],
  [:crop_north_imagemagick, ->(d) { DiscourseImageProcessing.crop(JPG, File.join(d, "crop.jpg"), 400, 400, backend: :imagemagick, max_pixels: 100_000_000) }, [400, 400, "jpg"]],
  [:downsize_50_imagemagick, ->(d) { DiscourseImageProcessing.downsize(PNG, File.join(d, "down-im.png"), "50%", backend: :imagemagick, max_pixels: 10_000_000) }, [1016, 656, "png"]],
  [:downsize_50_vips, ->(d) { DiscourseImageProcessing.downsize(PNG, File.join(d, "down-vips.png"), "50%", backend: :vips, max_pixels: 10_000_000) }, [1016, 656, "png"]],
  [:downsize_box_vips, ->(d) { DiscourseImageProcessing.downsize(PNG, File.join(d, "down-box.png"), "100x100>", backend: :vips, max_pixels: 10_000_000) }, [100, 65, "png"]],
  [:downsize_pixels_vips, ->(d) { DiscourseImageProcessing.downsize(PNG, File.join(d, "down-pixels.png"), "400000@", backend: :vips, max_pixels: 10_000_000) }, [787, 508, "png"]],
  [:convert_png_jpeg, ->(d) { DiscourseImageProcessing.convert_to_jpeg(PNG, File.join(d, "png.jpg"), quality: 85, max_pixels: 10_000_000) }, [2032, 1312, "jpg"]],
  [:convert_heic_jpeg, ->(d) { DiscourseImageProcessing.convert_to_jpeg(HEIC, File.join(d, "heic.jpg"), quality: 85, max_pixels: 10_000_000) }, [846, 1129, "jpg"]],
  [:ico_png, ->(d) { DiscourseImageProcessing.convert_favicon_to_png(ICO, File.join(d, "ico.png")) }, [1, 1, "png"]]
].freeze

Dir.mktmpdir do |dir|
  failures = []
  CASES.each do |name, callable, expected|
    result = callable.call(dir)
    actual = [result.width, result.height, result.output_format]
    failures << "#{name}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
    failures << "#{name}: output missing" unless result.output && File.file?(result.output) && File.size(result.output).positive?
  end

  svg = File.join(dir, "bad.svg")
  File.write(svg, %q{<svg onload="x"><script>x</script><rect width="1" height="1" onclick="x"/></svg>})
  DiscourseImageProcessing.sanitize_svg!(svg)
  sanitized = File.read(svg)
  failures << "svg sanitizer left dangerous content" if sanitized.match?(/script|onload|onclick/)

  abort failures.join("\n") if failures.any?
  puts "OK golden compatibility suite"
end
