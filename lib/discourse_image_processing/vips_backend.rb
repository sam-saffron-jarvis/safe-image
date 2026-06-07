# frozen_string_literal: true

module DiscourseImageProcessing
  module VipsBackend
    module_function

    DIMENSIONS_RE = /\A(?:(?<percent>\d+(?:\.\d+)?)%|(?<w>\d*)x(?<h>\d*)(?<only_down>>)?|(?<pixels>\d+)@)\z/

    def downsize(input:, output:, dimensions:, format:, quality: 85, max_pixels: nil)
      probe = DiscourseImageProcessing.probe(input, max_pixels: max_pixels)
      scale = scale_for(probe.width, probe.height, dimensions)
      scale = [scale, 1.0].min
      if scale >= 1.0
        FileUtils.cp(input, output)
        return {
          input_format: probe.input_format,
          output_format: format,
          width: probe.width,
          height: probe.height,
          duration_ms: 0.0
        }
      end
      Native.resize(input.to_s, output.to_s, scale, format.to_s, Integer(quality), max_pixels)
    end

    def scale_for(width, height, dimensions)
      dimensions = dimensions.to_s
      match = DIMENSIONS_RE.match(dimensions) or raise ArgumentError, "unsupported dimensions: #{dimensions.inspect}"

      if match[:percent]
        return Float(match[:percent]) / 100.0
      end

      if match[:pixels]
        target_pixels = Float(match[:pixels])
        return Math.sqrt(target_pixels / (Integer(width) * Integer(height)))
      end

      target_w = match[:w].to_s.empty? ? nil : Float(match[:w])
      target_h = match[:h].to_s.empty? ? nil : Float(match[:h])
      scales = []
      scales << target_w / width if target_w
      scales << target_h / height if target_h
      raise ArgumentError, "missing width/height in dimensions: #{dimensions.inspect}" if scales.empty?
      scales.min
    end
  end
end
