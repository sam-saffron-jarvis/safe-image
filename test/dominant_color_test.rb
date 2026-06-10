# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class DominantColorTest < TestCase
    HEX_COLOR = /\A\h{6}\z/

    def test_returns_hex_color_for_png
      assert_match HEX_COLOR, SafeImage.dominant_color(PNG, max_pixels: PNG_PIXELS)
    end

    def test_uses_first_frame_of_animated_gif
      assert_match HEX_COLOR, SafeImage.dominant_color(GIF, max_pixels: PNG_PIXELS)
    end

    def test_solid_color_image_reports_its_color_on_both_backends
      path = tmp_path("solid.png")
      SafeImage.letter_avatar(output: path, size: 16, background_rgb: [255, 0, 0], letter: " ", font: "Adwaita-Sans")

      assert_equal "FF0000", SafeImage.dominant_color(path)

      configure_safe_image(backend: :imagemagick)
      assert_equal "FF0000", SafeImage.dominant_color(path)
    end

    # vips computes the exact per-channel mean while ImageMagick averages
    # through its 1x1 resize filter, so allow a small per-channel drift.
    def test_backends_roughly_agree
      [PNG, GIF].each do |fixture|
        vips = SafeImage.dominant_color(fixture, max_pixels: PNG_PIXELS)

        configure_safe_image(backend: :imagemagick)
        magick = SafeImage.dominant_color(fixture, max_pixels: PNG_PIXELS)
        configure_safe_image(backend: :vips)

        vips.scan(/../).zip(magick.scan(/../)).each do |v, m|
          assert_in_delta v.to_i(16), m.to_i(16), 8,
            "channel drift on #{File.basename(fixture)} (vips=#{vips} imagemagick=#{magick})"
        end
      end
    end

    def test_ico_dominant_color_on_both_backends
      # vips backend: pure-Ruby ICO decode, vips averages the pixels.
      vips = SafeImage.dominant_color(ICO)
      assert_match HEX_COLOR, vips

      # imagemagick backend: ImageMagick's own ico decoder. The fixture is a
      # single pixel, so the backends must agree exactly.
      configure_safe_image(backend: :imagemagick)
      assert_equal vips, SafeImage.dominant_color(ICO)
    end

    def test_heic
      heic_or_skip do
        assert_match HEX_COLOR, SafeImage.dominant_color(HEIC, max_pixels: PNG_PIXELS)
      end
    end

    def test_enforces_max_pixels_on_both_backends
      assert_raises(LimitError) { SafeImage.dominant_color(JPG, max_pixels: 1_000) }

      configure_safe_image(backend: :imagemagick)
      assert_raises(LimitError) { SafeImage.dominant_color(JPG, max_pixels: 1_000) }
    end

    def test_rejects_svg
      path = write_tmp("icon.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>')

      assert_raises(UnsupportedFormatError) { SafeImage.dominant_color(path) }
    end

    def test_rejects_non_image_content
      path = write_tmp("fake.png", "not an image")

      assert_raises(Error) { SafeImage.dominant_color(path) }
    end

    def test_rejects_symlinked_input
      target = write_tmp("real.png", File.binread(PNG))
      link = tmp_path("link.png")
      File.symlink(target, link)

      assert_raises(UnsafePathError) { SafeImage.dominant_color(link) }
    end
  end
end
