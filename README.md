# discourse_image_processing

A first-cut, security-oriented image processing boundary for Discourse.

This gem intentionally does **not** depend on `ruby-vips`. It uses a tiny Ruby
native extension that calls `libvips` directly, so Discourse has one small API
surface for untrusted image bytes instead of scattered ImageMagick command
construction.

## Current scope

Implemented:

- explicit-format probe for JPEG, PNG, WebP, HEIF/HEIC and AVIF
- centre-cropped thumbnail generation with direct libvips backend
- optional ImageMagick compatibility backend for Discourse-exact resize/crop/downsize/convert/orient semantics
- explicit savers for JPEG, PNG, WebP and AVIF
- metadata stripping on save
- max-pixel guard
- optimisation stage:
  - `jpegoptim` for JPEG metadata stripping / optional quality cap
  - `oxipng` for PNG lossless optimisation
  - optional `pngquant` lossy PNG quantisation before `oxipng`
- Discourse compatibility facade for current call sites:
  - `resize`
  - `crop`
  - `downsize`
  - `convert_to_jpeg`
  - `fix_orientation`
  - `convert_favicon_to_png`
  - `optimize_image!`
  - `sanitize_svg!`
- SVG sanitisation via stdlib REXML allowlist
- ICO largest-frame extraction via explicit ImageMagick compatibility backend
- libvips `VIPS_BLOCK_UNTRUSTED` equivalent enabled in-process
- ImageMagick/Magick loaders blocked by libvips operation class
- libvips cache disabled by default in-process
- command execution uses argv arrays, not shell strings

Not implemented yet:

- Landlock sandboxing for every compatibility helper; thumbnail supports worker sandbox now, shell-based compatibility helpers still use bounded argv execution unless routed through a sandboxed worker path
- native-vips north/top crop parity for Discourse avatar crop; ImageMagick remains the exact compatibility backend for that path

## Why this exists

Discourse image processing is currently spread through models, helpers, upload
code, ImageMagick command builders and optimiser wrappers. This gem is intended
to become the single choke point for image decode/transform/optimise/validate.

ImageMagick delegates are deliberately avoided in the default libvips path. Loading is
by explicit libvips loader selected from an allowlisted extension, not generic
sniffing/fallback. At initialisation the native extension enables libvips'
untrusted-operation block and blocks known Magick loader classes
(`VipsForeignLoadMagick*`).

ImageMagick is available as an explicit compatibility backend only. It is never
selected implicitly, it is called with argv arrays rather than shell strings, and
its paths are restricted to a conservative absolute-path character set to avoid
ImageMagick pseudo-filename option parsing surprises.

## Install

System dependency: `libvips` headers and library.

Optional command dependencies for compatibility/optimisation paths:

- `magick` for ImageMagick compatibility operations
- `jpegoptim` for JPEG optimisation
- `oxipng` for PNG lossless optimisation
- `pngquant` for optional lossy PNG optimisation

Ruby runtime dependencies:

- `rexml` for SVG sanitising
- `landlock` for optional Linux subprocess sandboxing

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

# Compatibility-shaped methods for Discourse integration:
DiscourseImageProcessing.resize("in.jpg", "thumb.jpg", 600, 400, backend: :vips)
DiscourseImageProcessing.crop("in.jpg", "avatar.jpg", 240, 240, backend: :imagemagick)
DiscourseImageProcessing.downsize("in.png", "smaller.png", "50%")
DiscourseImageProcessing.convert_to_jpeg("in.png", "out.jpg", quality: 85)
DiscourseImageProcessing.fix_orientation("in.jpg")
DiscourseImageProcessing.convert_favicon_to_png("favicon.ico", "favicon.png")
DiscourseImageProcessing.optimize_image!("out.jpg")
DiscourseImageProcessing.optimize_image!("out.png", allow_lossy_png: true)
DiscourseImageProcessing.sanitize_svg!("icon.svg")

# Run a thumbnail operation in a subprocess with Landlock/SafeExec when available.
DiscourseImageProcessing.thumbnail(
  input: "input.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  execution: :sandbox
)
DiscourseImageProcessing.sandbox_available?
```

## License

MIT. `libvips` itself is LGPL-2.1-or-later and is dynamically linked.
