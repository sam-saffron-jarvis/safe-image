# frozen_string_literal: true

require "zlib"

# Hand-rolled PNG writers for crafting inputs the fixtures can't provide:
# decompression bombs and ancillary metadata chunks.
module PngFactory
  module_function

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  # A valid solid-grayscale PNG of arbitrary dimensions. All-zero scanlines
  # compress to almost nothing, so this is a tiny file whose IHDR advertises a
  # large pixel count — exactly what a decompression bomb looks like.
  def write_solid_png(path, width, height)
    ihdr = [width, height].pack("NN") + [8, 0, 0, 0, 0].pack("C5")
    deflate = Zlib::Deflate.new
    row = "\x00".b * (width + 1)
    idat = +"".b
    # SYNC_FLUSH forces output on every call; zlib-ng raises Zlib::BufError
    # when a Z_NO_FLUSH deflate consumes input without producing output.
    height.times { idat << deflate.deflate(row, Zlib::SYNC_FLUSH) }
    idat << deflate.finish
    File.binwrite(path, "\x89PNG\r\n\x1a\n".b + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", ""))
  end

  # Copies src to dst with an ancillary tEXt chunk inserted before IEND, so a
  # test can prove a re-encode dropped the input metadata.
  def append_text_chunk(src, dst, marker)
    data = File.binread(src)
    insert_at = data.rindex("IEND") - 4
    text = chunk("tEXt", "Comment\x00".b + marker.b)
    File.binwrite(dst, data[0...insert_at] + text + data[insert_at..])
  end
end
