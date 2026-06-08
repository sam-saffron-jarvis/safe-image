# frozen_string_literal: true

require_relative "safe_image/version"

module SafeImage
  class Error < StandardError; end
  class UnsupportedFormatError < Error; end
  class UnsafePathError < Error; end
  class InvalidImageError < Error; end
  class LimitError < Error; end
end

require_relative "safe_image/native"
require_relative "safe_image/result"
require_relative "safe_image/runner"
require_relative "safe_image/sandbox"
require_relative "safe_image/path_safety"
require_relative "safe_image/optimizer"
require_relative "safe_image/svg_sanitizer"
require_relative "safe_image/image_magick_backend"
require_relative "safe_image/vips_backend"
require_relative "safe_image/processor"
require_relative "safe_image/discourse_compat"

module SafeImage
  module_function

  @sandbox_enabled = false

  def enable_sandbox!
    raise Error, "landlock sandbox requested but unavailable" unless Sandbox.available?
    @sandbox_enabled = true
  end

  def disable_sandbox!
    @sandbox_enabled = false
  end

  def sandbox_enabled?
    @sandbox_enabled && ENV["SAFE_IMAGE_SANDBOX_CHILD"] != "1"
  end

  def with_sandbox_disabled
    previous = @sandbox_enabled
    @sandbox_enabled = false
    yield
  ensure
    @sandbox_enabled = previous
  end

  def sandbox_available? = Sandbox.available?

  def sandbox_call(operation, args: [], kwargs: {})
    Sandbox.public_call!(operation, args: args, kwargs: kwargs)
  end

  def maybe_sandbox(operation, args: [], kwargs: {})
    return yield unless sandbox_enabled?

    sandbox_call(operation, args: args, kwargs: kwargs)
  end

  def probe(path, max_pixels: nil)
    maybe_sandbox(:probe, args: [path], kwargs: { max_pixels: max_pixels }) do
      Processor.new(max_pixels: max_pixels).probe(path)
    end
  end

  def thumbnail(input:, output:, width:, height:, format: nil, quality: 85, max_pixels: nil, backend: :vips, optimize: false, optimize_mode: :lossless, execution: :inline)
    maybe_sandbox(
      :thumbnail,
      kwargs: {
        input: input,
        output: output,
        width: width,
        height: height,
        format: format,
        quality: quality,
        max_pixels: max_pixels,
        backend: backend,
        optimize: optimize,
        optimize_mode: optimize_mode,
        execution: :inline
      }
    ) do
      Processor.new(max_pixels: max_pixels, backend: backend, execution: execution).thumbnail(
        input: input,
        output: output,
        width: width,
        height: height,
        format: format,
        quality: quality,
        optimize: optimize,
        optimize_mode: optimize_mode
      )
    end
  end

  def optimize(path, mode: :lossless, strip_metadata: true, quality: nil, strict: true)
    maybe_sandbox(:optimize, args: [path], kwargs: { mode: mode, strip_metadata: strip_metadata, quality: quality, strict: strict }) do
      Optimizer.optimize(path, mode: mode, strip_metadata: strip_metadata, quality: quality, strict: strict)
    end
  end

  def resize(*args, **kwargs)
    maybe_sandbox(:resize, args: args, kwargs: kwargs) { DiscourseCompat.resize(*args, **kwargs) }
  end

  def crop(*args, **kwargs)
    maybe_sandbox(:crop, args: args, kwargs: kwargs) { DiscourseCompat.crop(*args, **kwargs) }
  end

  def downsize(*args, **kwargs)
    maybe_sandbox(:downsize, args: args, kwargs: kwargs) { DiscourseCompat.downsize(*args, **kwargs) }
  end

  def convert_to_jpeg(*args, **kwargs)
    maybe_sandbox(:convert_to_jpeg, args: args, kwargs: kwargs) { DiscourseCompat.convert_to_jpeg(*args, **kwargs) }
  end

  def fix_orientation(*args, **kwargs)
    maybe_sandbox(:fix_orientation, args: args, kwargs: kwargs) { DiscourseCompat.fix_orientation(*args, **kwargs) }
  end

  def convert_favicon_to_png(*args, **kwargs)
    maybe_sandbox(:convert_favicon_to_png, args: args, kwargs: kwargs) { DiscourseCompat.convert_favicon_to_png(*args, **kwargs) }
  end

  def frame_count(*args, **kwargs)
    maybe_sandbox(:frame_count, args: args, kwargs: kwargs) { DiscourseCompat.frame_count(*args, **kwargs) }
  end

  def animated?(*args, **kwargs)
    maybe_sandbox(:animated?, args: args, kwargs: kwargs) { DiscourseCompat.animated?(*args, **kwargs) }
  end

  def letter_avatar(*args, **kwargs)
    maybe_sandbox(:letter_avatar, args: args, kwargs: kwargs) { DiscourseCompat.letter_avatar(*args, **kwargs) }
  end

  def optimize_image!(*args, **kwargs)
    maybe_sandbox(:optimize_image!, args: args, kwargs: kwargs) { DiscourseCompat.optimize_image!(*args, **kwargs) }
  end

  def sanitize_svg!(*args, **kwargs)
    maybe_sandbox(:sanitize_svg!, args: args, kwargs: kwargs) { SvgSanitizer.sanitize!(*args, **kwargs) }
  end
end
