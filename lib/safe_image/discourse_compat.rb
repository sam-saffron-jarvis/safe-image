# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tempfile"

module SafeImage
  # Compatibility-shaped API for the operations Discourse currently performs in
  # OptimizedImage, UploadCreator, ShrinkUploadedImage and FileHelper.
  module DiscourseCompat
    module_function

    def resize(from, to, width, height, quality: nil, backend: :imagemagick, optimize: true, max_pixels: nil, encoder: :auto, chroma_subsampling: :auto)
      if backend.to_sym == :vips
        return SafeImage.thumbnail(
          input: from,
          output: to,
          width: width,
          height: height,
          quality: quality || 85,
          backend: backend,
          optimize: optimize,
          max_pixels: max_pixels,
          encoder: encoder,
          chroma_subsampling: chroma_subsampling
        )
      end

      probe = compat_probe(from, backend: :imagemagick, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
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

    def crop(from, to, width, height, quality: nil, backend: :imagemagick, optimize: true, max_pixels: nil, encoder: :auto, chroma_subsampling: :auto)
      probe = compat_probe(from, backend: backend, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      format = File.extname(output).delete_prefix(".").downcase

      info =
        if backend.to_sym == :vips && use_jpegli_for_generated_jpeg?(format, backend, encoder)
          with_temp_png(output) do |tmp_path|
            VipsBackend.crop_north(
              input: probe.input,
              output: tmp_path,
              width: width,
              height: height,
              format: "png",
              quality: 100,
              max_pixels: max_pixels
            )
            JpegliBackend.encode(
              input: tmp_path,
              output: output,
              quality: quality || JpegliBackend::DEFAULT_QUALITY,
              chroma_subsampling: JpegliBackend.validate_chroma_subsampling!(chroma_subsampling, input_format: probe.input_format),
              input_format: probe.input_format
            )
          end
        elsif backend.to_sym == :vips
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
      result_from_info(probe.input, output, info, compat_backend_name(backend, info))
    end

    def downsize(from, to, dimensions, backend: :imagemagick, optimize: true, max_pixels: nil, quality: 85, encoder: :auto, chroma_subsampling: :auto)
      probe = compat_probe(from, backend: backend, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      format = File.extname(output).delete_prefix(".").downcase
      info =
        if backend.to_sym == :vips && use_jpegli_for_generated_jpeg?(format, backend, encoder)
          with_temp_png(output) do |tmp_path|
            VipsBackend.downsize(
              input: probe.input,
              output: tmp_path,
              dimensions: dimensions,
              format: "png",
              quality: 100,
              max_pixels: max_pixels
            )
            JpegliBackend.encode(
              input: tmp_path,
              output: output,
              quality: quality,
              chroma_subsampling: JpegliBackend.validate_chroma_subsampling!(chroma_subsampling, input_format: probe.input_format),
              input_format: probe.input_format
            )
          end
        elsif backend.to_sym == :vips
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
      result_from_info(probe.input, output, info, compat_backend_name(backend, info))
    end

    def convert(from, to, format:, quality: nil, optimize: true, max_pixels: nil, encoder: :auto, chroma_subsampling: :auto)
      probe = compat_probe(from, backend: :imagemagick, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      normalized_format = format.to_s.downcase == "jpeg" ? "jpg" : format.to_s.downcase

      info =
        if use_jpegli_for_convert?(probe.input, normalized_format, encoder)
          JpegliBackend.convert(
            input: probe.input,
            output: output,
            quality: quality || JpegliBackend::DEFAULT_QUALITY,
            chroma_subsampling: chroma_subsampling
          )
        else
          if encoder.to_sym == :cjpegli
            raise UnsupportedFormatError, "cjpegli cannot directly encode #{File.extname(probe.input).delete_prefix(".").downcase.inspect}; use encoder: :auto or another encoder"
          end
          ImageMagickBackend.convert(input: probe.input, output: output, format: format, quality: quality)
        end

      Optimizer.optimize(output, mode: :lossless, strip_metadata: true, quality: normalized_format == "jpg" ? quality : nil) if optimize && info[:encoder] != "cjpegli"
      result_from_info(probe.input, output, info, info[:encoder] == "cjpegli" ? "cjpegli" : "imagemagick")
    end

    def use_jpegli_for_convert?(input, normalized_format, encoder)
      encoder = encoder.to_sym
      return false unless normalized_format == "jpg"
      return false if encoder == :imagemagick
      raise ArgumentError, "unknown encoder: #{encoder.inspect}" unless %i[auto cjpegli].include?(encoder)
      return true if encoder == :cjpegli && JpegliBackend.suitable_direct_input?(input)
      encoder == :auto && JpegliBackend.available? && JpegliBackend.suitable_direct_input?(input)
    end

    def use_jpegli_for_generated_jpeg?(format, backend, encoder)
      encoder = encoder.to_sym
      normalized_format = format.to_s.downcase == "jpeg" ? "jpg" : format.to_s.downcase
      return false unless normalized_format == "jpg"
      return false if %i[vips imagemagick magick].include?(encoder)
      raise ArgumentError, "unknown encoder: #{encoder.inspect}" unless %i[auto cjpegli].include?(encoder)
      raise ArgumentError, "encoder: :cjpegli currently requires backend: :vips" if encoder == :cjpegli && backend.to_sym != :vips
      encoder == :cjpegli || (backend.to_sym == :vips && JpegliBackend.available?)
    end

    def with_temp_png(output)
      output_path = Pathname.new(output)
      output_path.dirname.mkpath
      Tempfile.create([output_path.basename(".*").to_s, ".safe-image.png"], output_path.dirname.to_s) do |tmp|
        tmp_path = Pathname.new(tmp.path)
        tmp.close
        yield tmp_path
      ensure
        FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path
      end
    end

    def compat_backend_name(backend, info)
      base = backend.to_sym == :vips ? "libvips-direct" : "imagemagick"
      info[:encoder] == "cjpegli" ? "#{base}+cjpegli" : base
    end

    def convert_to_jpeg(from, to, quality: nil, optimize: true, max_pixels: nil, encoder: :auto, chroma_subsampling: :auto)
      convert(from, to, format: "jpg", quality: quality, optimize: optimize, max_pixels: max_pixels, encoder: encoder, chroma_subsampling: chroma_subsampling)
    end

    def fix_orientation(from, to = from, max_pixels: nil)
      probe = compat_probe(from, backend: :imagemagick, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      info = ImageMagickBackend.fix_orientation(input: probe.input, output: output)
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def convert_favicon_to_png(from, to, optimize: true, max_pixels: nil)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      info = Ico.convert_to_png(from, output, max_pixels: max_pixels)
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true) if optimize
      result_from_info(from, output, info, "ico-ruby+libvips")
    end

    def frame_count(path, max_pixels: nil)
      # ico directories are counted by the pure-Ruby parser; everything else
      # is a header-only native count via the n-pages field. ImageMagick is
      # the last resort for formats neither path knows.
      return Ico.frame_count(path, max_pixels: max_pixels) if File.extname(PathSafety.local_path(path)).downcase == ".ico"

      VipsBackend.frame_count(path, max_pixels: max_pixels)
    rescue UnsupportedFormatError
      ImageMagickBackend.frame_count(path, max_pixels: max_pixels)
    end

    def animated?(path, max_pixels: nil)
      frame_count(path, max_pixels: max_pixels).to_i > 1
    end

    def letter_avatar(output:, size:, background_rgb:, letter:, pointsize: 280, font: "DejaVu-Sans", backend: :auto)
      output = PathSafety.ensure_safe_output_path!(output).to_s
      request = { output: output, size: size, background_rgb: background_rgb, letter: letter, pointsize: pointsize, font: font }

      info, backend_name =
        case backend.to_sym
        when :vips
          [VipsBackend.letter_avatar(**request), "libvips-direct"]
        when :imagemagick, :magick
          [ImageMagickBackend.letter_avatar(**request), "imagemagick"]
        when :auto
          # Native Pango rendering; ImageMagick only when this libvips build
          # has no text support.
          begin
            [VipsBackend.letter_avatar(**request), "libvips-direct"]
          rescue UnsupportedFormatError
            [ImageMagickBackend.letter_avatar(**request), "imagemagick"]
          end
        else
          raise ArgumentError, "unknown backend: #{backend.inspect}"
        end

      result_from_info("generated", output, info, backend_name)
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
