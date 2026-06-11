# frozen_string_literal: true

require "tempfile"

module SafeImage
  module Optimizer
    module_function

    MAX_PNGQUANT_SIZE = 500_000

    # EXIF orientation values mapped onto jpegtran's lossless transforms.
    JPEGTRAN_OPERATIONS = {
      2 => ["-flip", "horizontal"],
      3 => ["-rotate", "180"],
      4 => ["-flip", "vertical"],
      5 => ["-transpose"],
      6 => ["-rotate", "90"],
      7 => ["-transverse"],
      8 => ["-rotate", "270"]
    }.freeze

    # assume_upright: skips the JPEG orientation check; only for callers
    # optimising output this gem just encoded (which is always upright).
    def optimize(path, mode: :lossless, strip_metadata: true, quality: nil, timeout: Runner::DEFAULT_TIMEOUT, strict: true, assume_upright: false)
      path = PathSafety.ensure_regular_file!(path)

      ext = path.extname.delete_prefix(".").downcase
      ext = "jpg" if ext == "jpeg"

      before = File.size(path)
      tools = []
      rotated_from = nil
      trimmed = false

      case ext
      when "jpg"
        # Stripping metadata deletes the EXIF orientation tag, so an oriented
        # image must have the rotation baked into its pixels first or it ships
        # sideways. jpegtran does that losslessly; without it, leave the file
        # untouched rather than strip-without-rotate.
        orientation = strip_metadata && !assume_upright ? jpeg_orientation(path) : 1
        if orientation > 1
          unless Runner.available?("jpegtran")
            raise Error, "jpegtran is required to optimize a JPEG with EXIF orientation" if strict
            return { format: ext, before_bytes: before, after_bytes: before, saved_bytes: 0, tools: tools, rotated_from: nil, trimmed: false }
          end
          trimmed = upright!(path, orientation, timeout: timeout)
          rotated_from = orientation
          tools << "jpegtran"
        end

        if Runner.available?("jpegoptim")
          argv = ["jpegoptim", "--quiet"]
          argv << (strip_metadata ? "--strip-all" : "--strip-none")
          argv << "--max=#{Integer(quality)}" if quality
          argv << path.to_s
          Runner.run!(argv, timeout: timeout)
          tools << "jpegoptim"
        else
          raise Error, "jpegoptim is required for strict JPEG optimisation" if strict
        end
      when "png"
        if mode.to_sym == :lossy && before < MAX_PNGQUANT_SIZE
          if Runner.available?("pngquant")
            tmp = Tempfile.new([path.basename(".*").to_s, ".pngquant.png"], path.dirname.to_s)
            tmp_path = Pathname.new(tmp.path)
            tmp.close
            begin
              argv = ["pngquant", "--force", "--skip-if-larger", "--output", tmp_path.to_s]
              argv << "--quality=#{quality}" if quality # e.g. "65-90"
              argv << path.to_s
              Runner.run!(argv, timeout: timeout)
              if tmp_path.file? && File.size(tmp_path) < File.size(path)
                FileUtils.mv(tmp_path, path)
                tools << "pngquant"
              end
            ensure
              FileUtils.rm_f(tmp_path)
            end
          elsif strict
            raise Error, "pngquant is required for strict lossy PNG optimisation"
          end
        end

        if Runner.available?("oxipng")
          argv = ["oxipng", "--quiet", "-o", "3"]
          argv.concat(["--strip", strip_metadata ? "safe" : "none"])
          argv << path.to_s
          Runner.run!(argv, timeout: timeout)
          tools << "oxipng"
        else
          raise Error, "oxipng is required for strict PNG optimisation" if strict
        end
      else
        raise UnsupportedFormatError, "unsupported optimize format: #{ext.inspect}"
      end

      after = File.size(path)
      {
        format: ext,
        before_bytes: before,
        after_bytes: after,
        saved_bytes: before - after,
        tools: tools,
        rotated_from: rotated_from,
        trimmed: trimmed
      }
    end

    def jpeg_orientation(path)
      case SafeImage.config.backend
      when :vips then VipsBackend.orientation(path.to_s)
      when :imagemagick then ImageMagickBackend.orientation(path.to_s)
      end
    end

    # Applies the orientation's lossless jpegtran transform in place, dropping
    # the metadata in the same pass (-copy none; this path only runs when
    # strip_metadata is set). -perfect refuses dimensions that are not
    # MCU-aligned; the -trim retry drops the partial edge blocks (under one
    # MCU, at most 15px) instead of hiding a lossy re-encode here. Returns
    # true when the fallback trimmed.
    def upright!(path, orientation, timeout:)
      transform = JPEGTRAN_OPERATIONS.fetch(orientation)
      tmp = Tempfile.new([path.basename(".*").to_s, ".jpegtran.jpg"], path.dirname.to_s)
      tmp_path = Pathname.new(tmp.path)
      tmp.close
      begin
        trimmed = false
        begin
          Runner.run!(["jpegtran", "-copy", "none", "-perfect", *transform, "-outfile", tmp_path.to_s, path.to_s], timeout: timeout)
        rescue CommandError
          Runner.run!(["jpegtran", "-copy", "none", "-trim", *transform, "-outfile", tmp_path.to_s, path.to_s], timeout: timeout)
          trimmed = true
        end
        FileUtils.mv(tmp_path, path)
        trimmed
      ensure
        FileUtils.rm_f(tmp_path)
      end
    end
  end
end
