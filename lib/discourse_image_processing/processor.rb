# frozen_string_literal: true

require "fileutils"
require "pathname"

module DiscourseImageProcessing
  class Processor
    SUPPORTED_INPUTS = %w[jpg jpeg png webp heic heif avif].freeze
    SUPPORTED_OUTPUTS = %w[jpg jpeg png webp avif].freeze

    def initialize(max_pixels: nil)
      @max_pixels = max_pixels
    end

    def probe(path)
      input = safe_existing_file!(path)
      info = Native.probe(input.to_s)
      validate_pixels!(info.fetch(:width), info.fetch(:height))
      Result.new(
        input: input.to_s,
        output: nil,
        input_format: info.fetch(:format),
        output_format: nil,
        width: info.fetch(:width),
        height: info.fetch(:height),
        filesize: File.size(input),
        backend: "libvips-direct",
        duration_ms: info.fetch(:duration_ms)
      )
    end

    def thumbnail(input:, output:, width:, height:, format: nil, quality: 85)
      input = safe_existing_file!(input)
      output = safe_output_path!(output)
      width = Integer(width)
      height = Integer(height)
      quality = Integer(quality)
      raise ArgumentError, "width and height must be positive" if width <= 0 || height <= 0
      raise ArgumentError, "quality must be 1..100" unless (1..100).cover?(quality)

      out_format = (format || output.extname.delete_prefix(".")).downcase
      out_format = "jpg" if out_format == "jpeg"
      unless SUPPORTED_OUTPUTS.include?(out_format)
        raise UnsupportedFormatError, "unsupported output format: #{out_format.inspect}"
      end

      output.dirname.mkpath
      info = Native.thumbnail(input.to_s, output.to_s, width, height, out_format, quality, @max_pixels)
      Result.new(
        input: input.to_s,
        output: output.to_s,
        input_format: info.fetch(:input_format),
        output_format: info.fetch(:output_format),
        width: info.fetch(:width),
        height: info.fetch(:height),
        filesize: File.size(output),
        backend: "libvips-direct",
        duration_ms: info.fetch(:duration_ms)
      )
    end

    private

    def safe_existing_file!(path)
      path = Pathname.new(path).expand_path
      raise UnsafePathError, "path contains NUL" if path.to_s.include?("\0")
      raise UnsafePathError, "not a file: #{path}" unless path.file?
      ext = path.extname.delete_prefix(".").downcase
      ext = "jpg" if ext == "jpeg"
      raise UnsupportedFormatError, "unsupported input format: #{ext.inspect}" unless SUPPORTED_INPUTS.include?(ext)
      path
    end

    def safe_output_path!(path)
      path = Pathname.new(path).expand_path
      raise UnsafePathError, "path contains NUL" if path.to_s.include?("\0")
      path
    end

    def validate_pixels!(width, height)
      return unless @max_pixels
      pixels = Integer(width) * Integer(height)
      raise LimitError, "image has #{pixels} pixels, exceeds #{@max_pixels}" if pixels > @max_pixels
    end
  end
end
