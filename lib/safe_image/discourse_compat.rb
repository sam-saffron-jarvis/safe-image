# frozen_string_literal: true

module SafeImage
  # Compatibility-shaped API for the operations Discourse currently performs in
  # OptimizedImage, UploadCreator, ShrinkUploadedImage and FileHelper.
  module DiscourseCompat
    module_function

    def resize(from, to, width, height, quality: nil, backend: :imagemagick, optimize: true, max_pixels: nil)
      if backend.to_sym == :vips
        return SafeImage.thumbnail(
          input: from,
          output: to,
          width: width,
          height: height,
          quality: quality || 85,
          backend: backend,
          optimize: optimize,
          max_pixels: max_pixels
        )
      end

      probe = compat_probe(from, backend: :imagemagick, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      info = ImageMagickBackend.thumbnail(
        input: probe.input,
        output: output,
        width: width,
        height: height,
        format: File.extname(output).delete_prefix(".").downcase,
        quality: quality
      )
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true, quality: quality) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def crop(from, to, width, height, quality: nil, backend: :imagemagick, optimize: true, max_pixels: nil)
      probe = compat_probe(from, backend: backend, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      format = File.extname(output).delete_prefix(".").downcase

      info =
        if backend.to_sym == :vips
          VipsBackend.crop_north(
            input: probe.input,
            output: output,
            width: width,
            height: height,
            format: format,
            quality: quality || 85,
            max_pixels: max_pixels
          )
        else
          ImageMagickBackend.resize_like(
            input: probe.input,
            output: output,
            width: width,
            height: height,
            format: format,
            quality: quality,
            crop: :north
          )
        end
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true, quality: quality) if optimize
      result_from_info(probe.input, output, info, backend.to_sym == :vips ? "libvips-direct" : "imagemagick")
    end

    def downsize(from, to, dimensions, backend: :imagemagick, optimize: true, max_pixels: nil, quality: 85)
      probe = compat_probe(from, backend: backend, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      format = File.extname(output).delete_prefix(".").downcase
      info =
        if backend.to_sym == :vips
          VipsBackend.downsize(
            input: probe.input,
            output: output,
            dimensions: dimensions,
            format: format,
            quality: quality,
            max_pixels: max_pixels
          )
        else
          ImageMagickBackend.downsize(
            input: probe.input,
            output: output,
            dimensions: dimensions,
            format: format
          )
        end
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true) if optimize
      result_from_info(probe.input, output, info, backend.to_sym == :vips ? "libvips-direct" : "imagemagick")
    end

    def convert_to_jpeg(from, to, quality: nil, optimize: true, max_pixels: nil)
      probe = compat_probe(from, backend: :imagemagick, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      info = ImageMagickBackend.convert_to_jpeg(input: probe.input, output: output, quality: quality)
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true, quality: quality) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def fix_orientation(from, to = from, max_pixels: nil)
      probe = compat_probe(from, backend: :imagemagick, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      info = ImageMagickBackend.fix_orientation(input: probe.input, output: output)
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def convert_favicon_to_png(from, to, optimize: true, max_pixels: nil)
      frame_count(from, max_pixels: max_pixels) if max_pixels
      output = Pathname.new(to).expand_path.to_s
      info = ImageMagickBackend.convert_ico_to_png(input: Pathname.new(from).expand_path.to_s, output: output)
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true) if optimize
      result_from_info(from, output, info, "imagemagick")
    end

    def frame_count(path, max_pixels: nil)
      ImageMagickBackend.frame_count(path, max_pixels: max_pixels)
    end

    def animated?(path, max_pixels: nil)
      frame_count(path, max_pixels: max_pixels).to_i > 1
    end

    def letter_avatar(output:, size:, background_rgb:, letter:, pointsize: 280, font: "NimbusSans-Regular")
      info = ImageMagickBackend.letter_avatar(
        output: Pathname.new(output).expand_path.to_s,
        size: size,
        background_rgb: background_rgb,
        letter: letter,
        pointsize: pointsize,
        font: font
      )
      result_from_info("generated", output, info, "imagemagick")
    end

    def optimize_image!(path, allow_lossy_png: false, strip_metadata: true, quality: nil, strict: true)
      Optimizer.optimize(
        path,
        mode: allow_lossy_png ? :lossy : :lossless,
        strip_metadata: strip_metadata,
        quality: quality,
        strict: strict
      )
    end

    def compat_probe(path, backend:, max_pixels: nil)
      path = Pathname.new(path).expand_path.to_s
      if backend.to_sym == :vips
        SafeImage.probe(path, max_pixels: max_pixels)
      else
        info = ImageMagickBackend.probe(path, max_pixels: max_pixels)
        Result.new(
          input: path,
          output: nil,
          input_format: info.fetch(:input_format),
          output_format: nil,
          width: info.fetch(:width),
          height: info.fetch(:height),
          filesize: File.size(path),
          backend: "imagemagick",
          duration_ms: info.fetch(:duration_ms),
          optimizer: nil
        )
      end
    end

    def result_from_info(input, output, info, backend)
      Result.new(
        input: input.to_s,
        output: output.to_s,
        input_format: info.fetch(:input_format),
        output_format: info.fetch(:output_format),
        width: info.fetch(:width),
        height: info.fetch(:height),
        filesize: File.size(output),
        backend: backend,
        duration_ms: info.fetch(:duration_ms),
        optimizer: nil
      )
    end
  end
end
