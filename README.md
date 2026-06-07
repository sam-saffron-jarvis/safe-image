# discourse_image_processing

A first-cut, security-oriented image processing boundary for Discourse.

This gem intentionally does **not** depend on `ruby-vips`. It uses a tiny Ruby
native extension that calls `libvips` directly, so Discourse has one small API
surface for untrusted image bytes instead of scattered ImageMagick command
construction.

## Current scope

Implemented:

- explicit-format probe for JPEG, PNG, WebP, HEIF/HEIC and AVIF
- centre-cropped thumbnail generation
- explicit savers for JPEG, PNG, WebP and AVIF
- metadata stripping on save
- max-pixel guard
- libvips `VIPS_BLOCK_UNTRUSTED` equivalent enabled in-process
- ImageMagick/Magick loaders blocked by libvips operation class
- libvips cache disabled by default in-process
- no ImageMagick, no shell-outs, no delegates

Not implemented yet:

- subprocess/Landlock execution mode
- oxipng/jpegoptim/pngquant optimisation stage
- SVG sanitisation
- ICO frame extraction
- top/north crop mode
- full Discourse compatibility layer

## Why this exists

Discourse image processing is currently spread through models, helpers, upload
code, ImageMagick command builders and optimiser wrappers. This gem is intended
to become the single choke point for image decode/transform/optimise/validate.

ImageMagick delegates are deliberately avoided. Loading is by explicit libvips
loader selected from an allowlisted extension, not generic sniffing/fallback.
At initialisation the native extension enables libvips' untrusted-operation
block and blocks known Magick loader classes (`VipsForeignLoadMagick*`).

## Install

System dependency: `libvips` headers and library.

```bash
gem build discourse_image_processing.gemspec
gem install ./discourse_image_processing-0.1.0.gem
```

## Usage

```ruby
require "discourse_image_processing"

info = DiscourseImageProcessing.probe("input.jpg", max_pixels: 40_000_000)

result = DiscourseImageProcessing.thumbnail(
  input: "input.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  quality: 85,
  max_pixels: 40_000_000
)

puts result.width
puts result.height
puts result.filesize
```

## License

MIT. `libvips` itself is LGPL-2.1-or-later and is dynamically linked.
