# frozen_string_literal: true

require "open3"
require "json"
require_relative "test_helper"

module SafeImage
  # The libvips binding loads at runtime, so a host with only ImageMagick
  # must keep working when configured with backend: :imagemagick — and
  # configure!(backend: :vips) must fail closed at boot, not on the first
  # request. Pure-Ruby paths (SVG, ICO metadata) never depend on libvips.
  # Exercised in a subprocess with the library override pointed at a name
  # that cannot resolve.
  class VipsUnavailableTest < TestCase
    SCRIPT = <<~'RUBY'
      require "safe_image"
      require "json"

      out = {}
      out[:available] = SafeImage::VipsGlue.available?

      begin
        SafeImage.configure!(backend: :vips, landlock: false)
        out[:vips_configure] = "no error"
      rescue SafeImage::Error
        out[:vips_configure] = "raised"
      end

      begin
        SafeImage.probe(ENV["JPG"])
        out[:unconfigured] = "no error"
      rescue SafeImage::NotConfiguredError
        out[:unconfigured] = "raised"
      end

      SafeImage.configure!(backend: :imagemagick, landlock: false)
      out[:probe_jpg] = SafeImage.probe(ENV["JPG"], max_pixels: 100_000_000).backend
      out[:probe_ico] = SafeImage.probe(ENV["ICO"]).backend
      out[:thumb] = SafeImage.thumbnail(input: ENV["JPG"], output: File.join(ENV["OUT"], "t.jpg"), width: 60, height: 40, max_pixels: 100_000_000).backend
      out[:resize] = SafeImage.resize(ENV["PNG"], File.join(ENV["OUT"], "r.png"), 100, 65, max_pixels: 10_000_000).backend
      out[:gif_convert] = SafeImage.convert(ENV["GIF"], File.join(ENV["OUT"], "g.png"), format: "png", max_pixels: 10_000_000).backend
      out[:dominant] = SafeImage.dominant_color(ENV["PNG"], max_pixels: 10_000_000)
      out[:dominant_ico] = SafeImage.dominant_color(ENV["ICO"])
      out[:avatar] = SafeImage.letter_avatar(output: File.join(ENV["OUT"], "a.png"), size: 64, background_rgb: [1, 2, 3], letter: "S").backend
      out[:favicon] = SafeImage.convert_favicon_to_png(ENV["ICO"], File.join(ENV["OUT"], "f.png")).backend
      out[:frames] = SafeImage.frame_count(ENV["GIF"], max_pixels: 10_000_000)
      out[:orientation] = SafeImage.orientation(ENV["JPG"])

      puts JSON.dump(out)
    RUBY

    def test_imagemagick_backend_works_without_libvips
      env = {
        "SAFE_IMAGE_LIBVIPS" => "libsafe-image-no-such-library.so.0",
        "JPG" => JPG, "PNG" => PNG, "GIF" => GIF, "ICO" => ICO, "OUT" => tmpdir
      }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", SCRIPT)

      assert status.success?, "vips-less child process failed:\n#{stderr}"
      out = JSON.parse(stdout.lines.last)

      assert_equal false, out["available"]
      assert_equal "raised", out["vips_configure"], "configure!(backend: :vips) must fail closed at boot"
      assert_equal "raised", out["unconfigured"], "operations before configure! must raise"
      assert_equal "imagemagick", out["probe_jpg"]
      assert_equal "ico-metadata", out["probe_ico"], "pure-Ruby paths must not depend on libvips"
      assert_equal "imagemagick", out["thumb"]
      assert_equal "imagemagick", out["resize"]
      assert_equal "imagemagick", out["gif_convert"]
      assert_match(/\A\h{6}\z/, out["dominant"])
      assert_match(/\A\h{6}\z/, out["dominant_ico"])
      assert_equal "imagemagick", out["avatar"]
      assert_equal "imagemagick", out["favicon"]
      assert_equal 20, out["frames"]
      assert_equal 1, out["orientation"]
    end
  end
end
