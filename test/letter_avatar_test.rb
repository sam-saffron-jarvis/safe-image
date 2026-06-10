# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class LetterAvatarTest < TestCase
    BG = [30, 60, 200].freeze

    def test_native_backend_renders
      result = SafeImage.letter_avatar(
        output: tmp_path("avatar.png"), size: 360, background_rgb: BG, letter: "S", backend: :vips
      )

      assert_result result, width: 360, height: 360, format: "png"
      assert_equal "libvips-direct", result.backend
    end

    def test_auto_prefers_the_native_backend
      result = SafeImage.letter_avatar(output: tmp_path("avatar.png"), size: 360, background_rgb: BG, letter: "S")

      assert_equal "libvips-direct", result.backend
    end

    def test_imagemagick_backend_remains_available
      result = SafeImage.letter_avatar(
        output: tmp_path("avatar.png"), size: 360, background_rgb: BG, letter: "S", backend: :imagemagick
      )

      assert_result result, width: 360, height: 360, format: "png"
      assert_equal "imagemagick", result.backend
    end

    def test_blank_letter_renders_the_exact_background
      SafeImage.letter_avatar(
        output: tmp_path("solid.png"), size: 16, background_rgb: [255, 0, 0], letter: " ", backend: :vips
      )

      assert_equal "FF0000", SafeImage.dominant_color(tmp_path("solid.png"))
    end

    def test_glyph_lightens_the_average_color
      plain = tmp_path("plain.png")
      lettered = tmp_path("lettered.png")
      SafeImage.letter_avatar(output: plain, size: 360, background_rgb: BG, letter: " ", backend: :vips)
      SafeImage.letter_avatar(output: lettered, size: 360, background_rgb: BG, letter: "M", backend: :vips)

      assert_operator SafeImage.dominant_color(lettered).to_i(16), :>, SafeImage.dominant_color(plain).to_i(16),
        "expected the white glyph blend to lighten the average colour"
    end

    def test_bundled_font_renders_deterministically
      first = tmp_path("first.png")
      second = tmp_path("second.png")
      SafeImage.letter_avatar(output: first, size: 360, background_rgb: BG, letter: "Q", font: "DejaVu-Sans", backend: :vips)
      SafeImage.letter_avatar(output: second, size: 360, background_rgb: BG, letter: "Q", font: "DejaVu-Sans", backend: :vips)

      assert_equal File.binread(first), File.binread(second)
    end

    def test_pango_markup_characters_render_as_glyphs
      %w[< & >].each do |letter|
        result = SafeImage.letter_avatar(
          output: tmp_path("markup.png"), size: 64, background_rgb: BG, letter: letter, backend: :vips
        )
        assert_result result, width: 64, height: 64, format: "png"
      end
    end

    def test_multibyte_grapheme_renders
      result = SafeImage.letter_avatar(output: tmp_path("umlaut.png"), size: 64, background_rgb: BG, letter: "Ä", backend: :vips)

      assert_result result, width: 64, height: 64, format: "png"
    end

    def test_rejects_unknown_font
      assert_raises(ArgumentError) do
        SafeImage.letter_avatar(output: tmp_path("a.png"), size: 64, background_rgb: BG, letter: "S", font: "Comic-Sans", backend: :vips)
      end
    end

    def test_rejects_unknown_backend
      assert_raises(ArgumentError) do
        SafeImage.letter_avatar(output: tmp_path("a.png"), size: 64, background_rgb: BG, letter: "S", backend: :gd)
      end
    end

    def test_rejects_invalid_background
      assert_raises(ArgumentError) do
        SafeImage.letter_avatar(output: tmp_path("a.png"), size: 64, background_rgb: [0, 0, 999], letter: "S", backend: :vips)
      end
    end
  end
end
