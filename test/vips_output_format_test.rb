# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # Downsize must always re-encode through libvips — never copy the untrusted
  # input bytes (and their metadata) through verbatim, even when no shrink is
  # needed.
  class VipsOutputFormatTest < TestCase
    def test_no_shrink_downsize_to_another_format_reencodes
      jpg = tmp_path("converted.jpg")
      SafeImage.downsize(PNG, jpg, "9999x9999>", optimize: false, max_pixels: JPG_PIXELS)

      assert_equal :jpeg, SafeImage.type(jpg, max_pixels: JPG_PIXELS), "PNG bytes copied to JPG output"
    end

    def test_noop_same_format_downsize_drops_input_metadata
      marker = "SAFE-IMAGE-DOWNSIZE-MARKER"
      marked = tmp_path("marked.png")
      PngFactory.append_text_chunk(PNG, marked, marker)
      assert_includes File.binread(marked), marker, "marker not injected"

      out = tmp_path("noop.png")
      SafeImage.downsize(marked, out, "200%", optimize: false, max_pixels: JPG_PIXELS)

      refute_includes File.binread(out), marker, "input metadata copied through"
    end
  end
end
