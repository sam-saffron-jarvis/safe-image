# frozen_string_literal: true

require "mkmf"

pkg_config("vips") or abort "libvips development files are required (pkg-config vips failed)"
have_header("vips/vips.h") or abort "missing vips/vips.h"
have_library("vips") or abort "missing libvips"
create_makefile("safe_image_native")
