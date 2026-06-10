# Security Policy

Safe Image is a hardened image-processing boundary for untrusted uploads, not a proof that hostile image bytes are harmless.

## Supported versions

Only the latest released gem version is supported; security fixes land on `main` and ship as the next release. Report against the latest released version unless you can reproduce on `main` as well.

## Threat model

Safe Image assumes image input may be attacker-controlled. The library is designed to reduce the number of places an application touches those bytes and to remove common image-processing foot-guns:

- shell-free external command execution using argv arrays
- allowlisted command environment
- bounded command output and process-group timeout cleanup
- explicit libvips loader selection for supported raster formats, with
  libvips' untrusted-operation block enabled and the ImageMagick loader
  classes blocked by name
- a runtime libvips binding (Fiddle) that exposes only the specific
  operations the gem invokes — there is no generic operation access
- no silent fallback from libvips to generic ImageMagick decoding; the
  backend is a single explicit `SafeImage.configure!` decision and formats it
  cannot decode fail closed
- decompression-bomb ceilings enforced from container/header metadata before
  any pixel decode (128MP default, plus dedicated SVG and ICO caps)
- restrictive ImageMagick policy disabling delegates, filters, `@file`, remote URL coders, Ghostscript-backed formats, and dangerous pseudo-formats
- risky container formats parsed in memory-safe Ruby rather than C: SVG
  (bounded REXML metadata and allowlist sanitising) and ICO (bounds-checked
  directory/DIB parsing); extracted pixels are re-encoded through libvips and
  embedded payload bytes are never copied through verbatim
- letter avatar text rendering escapes the user-derived glyph before Pango
  markup parsing, and fonts come from an allowlist (the default font is
  bundled with the gem)
- symlink rejection for untrusted local input/output paths
- remote fetch SSRF hardening: scheme/port restrictions, special-use IP blocking, DNS pinning, redirect limits, HTTPS-to-HTTP rejection, header allowlists, content-type/extension agreement, and probe-before-yield
- optional Linux Landlock/seccomp subprocess sandboxing

One deliberate exception to libvips' untrusted-operation block: the libjxl
loader and saver are re-enabled because JPEG XL is part of the supported
input surface. JXL inputs still pass extension routing, the pixel cap, and
(optionally) the Landlock sandbox, but libjxl does parse attacker-controlled
bytes in-process like the other raster decoders below.

## Non-goals

Safe Image does not claim that parsing hostile images in-process is memory-safe. Raster decoders such as libjpeg, libpng, libwebp, libheif, libjxl, libnsgif, libvips loaders, and ImageMagick coders still parse attacker-controlled bytes. A decoder memory-corruption bug or pathological resource-consumption bug is still possible.

The honest claim is defense-in-depth:

- without Landlock: centralized and hardened image processing with major delegate/protocol/policy foot-guns removed
- with Landlock: the same hardening plus a kernel containment boundary around subprocess-based public operations

If your deployment needs a hard isolation boundary, configure `landlock: true` and run image processing away from your main web worker process.

## Reporting vulnerabilities

Please report suspected security issues privately to `sam@discourse.org`.

Include:

- affected version or commit
- input file or minimized reproducer, if shareable
- operation/API called and the backend in use (libvips, ImageMagick, cjpegli)
- expected vs actual result
- whether Landlock sandboxing was enabled
- host OS, kernel, libvips, ImageMagick, and optimizer tool versions

Do not open a public issue for an exploitable crash, sandbox escape, SSRF bypass, arbitrary file read/write, command execution bug, or denial-of-service vector until there has been time to patch.
