# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class OptimizerTest < TestCase
    def test_optimize_image_runs_jpegoptim_on_jpeg
      jpg = tmp_path("converted.jpg")
      SafeImage.convert(PNG, jpg, format: "jpg", quality: 85, max_pixels: PNG_PIXELS)

      result = SafeImage.optimize_image!(jpg)
      assert_includes result.fetch(:tools), "jpegoptim"
    end

    def test_optimize_image_runs_oxipng_on_png
      png = tmp_path("down.png")
      SafeImage.downsize(PNG, png, "50%", max_pixels: PNG_PIXELS)

      result = SafeImage.optimize_image!(png, allow_lossy_png: true)
      assert_includes result.fetch(:tools), "oxipng"
    end

    def test_optimize_uprights_oriented_jpegs_losslessly_before_stripping
      skip "jpegtran unavailable" unless Runner.available?("jpegtran")
      path = oriented_jpg("opt-aligned.jpg", 6, width: 192, height: 128)

      result = SafeImage.optimize(path)

      assert_equal %w[jpegtran jpegoptim], result.fetch(:tools)
      assert_equal 6, result.fetch(:rotated_from)
      refute result.fetch(:trimmed)
      assert_equal 1, SafeImage.orientation(path)
      assert_equal [128, 192], SafeImage.size(path)
    end

    def test_optimize_trims_non_mcu_aligned_oriented_jpegs
      skip "jpegtran unavailable" unless Runner.available?("jpegtran")
      path = oriented_jpg("opt-ragged.jpg", 6, width: 201, height: 131)

      result = SafeImage.optimize(path)

      assert_equal 6, result.fetch(:rotated_from)
      assert result.fetch(:trimmed)
      assert_equal 1, SafeImage.orientation(path)
      # rotated 131x201, then the partial edge MCU is dropped: 131 -> 128
      assert_equal [128, 201], SafeImage.size(path)
    end

    def test_optimize_keeps_orientation_when_not_stripping
      path = oriented_jpg("opt-keep.jpg", 6, width: 192, height: 128)

      result = SafeImage.optimize(path, strip_metadata: false)

      refute_includes result.fetch(:tools), "jpegtran"
      assert_nil result.fetch(:rotated_from)
      assert_equal 6, SafeImage.orientation(path)
    end

    def test_optimize_uprights_oriented_jpegs_on_the_imagemagick_backend
      skip "jpegtran unavailable" unless Runner.available?("jpegtran")
      path = oriented_jpg("opt-im.jpg", 6, width: 192, height: 128)

      configure_safe_image(backend: :imagemagick)
      result = SafeImage.optimize(path)

      assert_equal 6, result.fetch(:rotated_from)
      assert_equal 1, SafeImage.orientation(path)
      assert_equal [128, 192], SafeImage.size(path)
    end

    # Internal contract: callers may only assert uprightness for files this
    # gem just encoded — no rotation is applied even when a tag is present.
    # (jpegoptim itself only rewrites when the result shrinks, so whether the
    # tag survives here depends on the file; the pixels must stay put.)
    def test_optimize_assume_upright_skips_the_orientation_check
      path = oriented_jpg("opt-internal.jpg", 6, width: 192, height: 128)

      result = Optimizer.optimize(path, assume_upright: true)

      refute_includes result.fetch(:tools), "jpegtran"
      assert_equal [192, 128], SafeImage.size(path)
    end
  end
end
