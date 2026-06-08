# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../lib/safe_image"

unless SafeImage.sandbox_available?
  warn "SKIP atomic sandbox suite: Landlock::SafeExec unavailable"
  exit 0
end

FIXTURES = File.expand_path("fixtures/images", __dir__)
JPG = File.join(FIXTURES, "huge.jpg")
PNG = File.join(FIXTURES, "large_and_unoptimized.png")
HEIC = File.join(FIXTURES, "should_be_jpeg.heic")
ICO = File.join(FIXTURES, "smallest.ico")
GIF = File.join(FIXTURES, "animated.gif")
WEBP = File.join(FIXTURES, "animated.webp")

Dir.mktmpdir do |dir|
  SafeImage.enable_sandbox!
  raise "sandbox not enabled" unless SafeImage.sandbox_enabled?

  results = []
  results << SafeImage.probe(JPG, max_pixels: 100_000_000)
  results << SafeImage.thumbnail(input: JPG, output: File.join(dir, "thumb.jpg"), width: 600, height: 400, optimize: true, max_pixels: 100_000_000)
  results << SafeImage.resize(JPG, File.join(dir, "resize.jpg"), 600, 400, optimize: true, max_pixels: 100_000_000)
  results << SafeImage.crop(JPG, File.join(dir, "crop-vips.jpg"), 400, 400, backend: :vips, optimize: true, max_pixels: 100_000_000)
  results << SafeImage.crop(JPG, File.join(dir, "crop-im.jpg"), 400, 400, backend: :imagemagick, optimize: true, max_pixels: 100_000_000)
  results << SafeImage.downsize(PNG, File.join(dir, "down-vips.png"), "50%", backend: :vips, max_pixels: 10_000_000)
  results << SafeImage.downsize(PNG, File.join(dir, "down-im.png"), "50%", backend: :imagemagick, max_pixels: 10_000_000)
  results << SafeImage.convert_to_jpeg(PNG, File.join(dir, "png.jpg"), quality: 85, max_pixels: 10_000_000)
  results << SafeImage.convert_to_jpeg(HEIC, File.join(dir, "heic.jpg"), quality: 85, max_pixels: 10_000_000)
  results << SafeImage.fix_orientation(JPG, File.join(dir, "oriented.jpg"), max_pixels: 100_000_000)
  results << SafeImage.convert_favicon_to_png(ICO, File.join(dir, "ico.png"), max_pixels: 10_000_000)

  frame_count = SafeImage.frame_count(GIF, max_pixels: 10_000_000)
  raise "bad frame count #{frame_count}" unless frame_count > 1
  raise "animated? false" unless SafeImage.animated?(GIF, max_pixels: 10_000_000)

  results << SafeImage.letter_avatar(output: File.join(dir, "letter.png"), size: 360, background_rgb: [1, 2, 3], letter: "S", font: "Adwaita-Sans")

  svg = File.join(dir, "bad.svg")
  File.write(svg, %q{<svg onload="x"><script>x</script><rect width="1" height="1" onclick="x"/></svg>})
  svg_result = SafeImage.sanitize_svg!(svg)
  raise "svg result bad" unless svg_result["sanitized"] || svg_result[:sanitized]
  raise "svg still unsafe" if File.read(svg).match?(/script|onload|onclick/)

  jpg_to_opt = File.join(dir, "opt.jpg")
  FileUtils.cp(JPG, jpg_to_opt)
  opt_method_result = SafeImage.optimize(jpg_to_opt, strict: true)
  raise "optimize did not run" unless opt_method_result.fetch("tools", opt_method_result[:tools]).include?("jpegoptim")

  jpg_to_opt_bang = File.join(dir, "opt-bang.jpg")
  FileUtils.cp(JPG, jpg_to_opt_bang)
  opt_result = SafeImage.optimize_image!(jpg_to_opt_bang, strict: true)
  raise "jpegoptim did not run" unless opt_result.fetch("tools", opt_result[:tools]).include?("jpegoptim")

  webp_thumb = SafeImage.thumbnail(input: WEBP, output: File.join(dir, "webp.jpg"), width: 120, height: 120, max_pixels: 10_000_000)
  results << webp_thumb

  results.each do |result|
    next unless result.respond_to?(:output) && result.output
    raise "missing output #{result.inspect}" unless File.file?(result.output) && File.size(result.output).positive?
  end

  puts "OK atomic sandbox all operations: #{results.size} result objects, frame_count=#{frame_count}"
end
