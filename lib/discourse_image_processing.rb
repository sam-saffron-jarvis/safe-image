# frozen_string_literal: true

require_relative "discourse_image_processing/version"

module DiscourseImageProcessing
  class Error < StandardError; end
  class UnsupportedFormatError < Error; end
  class UnsafePathError < Error; end
  class InvalidImageError < Error; end
  class LimitError < Error; end
end

require_relative "discourse_image_processing/native"
require_relative "discourse_image_processing/result"
require_relative "discourse_image_processing/processor"

module DiscourseImageProcessing
  module_function

  def probe(path, max_pixels: nil)
    Processor.new(max_pixels: max_pixels).probe(path)
  end

  def thumbnail(input:, output:, width:, height:, format: nil, quality: 85, max_pixels: nil)
    Processor.new(max_pixels: max_pixels).thumbnail(
      input: input,
      output: output,
      width: width,
      height: height,
      format: format,
      quality: quality
    )
  end
end
