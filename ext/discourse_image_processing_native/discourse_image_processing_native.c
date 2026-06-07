#include <ruby.h>
#include <vips/vips.h>
#include <sys/stat.h>
#include <string.h>
#include <time.h>

static VALUE mDIP;
static VALUE mNative;
static VALUE eError;
static VALUE eUnsupported;
static VALUE eInvalid;
static VALUE eLimit;

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static const char *extname(const char *path) {
  const char *dot = strrchr(path, '.');
  return dot ? dot + 1 : "";
}

static int streq_ci(const char *a, const char *b) {
#ifdef _WIN32
  return _stricmp(a, b) == 0;
#else
  return strcasecmp(a, b) == 0;
#endif
}

static const char *normalized_format(const char *fmt) {
  if (streq_ci(fmt, "jpg") || streq_ci(fmt, "jpeg")) return "jpg";
  if (streq_ci(fmt, "png")) return "png";
  if (streq_ci(fmt, "webp")) return "webp";
  if (streq_ci(fmt, "heic") || streq_ci(fmt, "heif")) return "heic";
  if (streq_ci(fmt, "avif")) return "avif";
  return NULL;
}

static void raise_vips(void) {
  const char *msg = vips_error_buffer();
  VALUE rb_msg = rb_str_new_cstr(msg && *msg ? msg : "libvips error");
  vips_error_clear();
  rb_exc_raise(rb_exc_new3(eInvalid, rb_msg));
}

static void init_vips_once(void) {
  static int initialized = 0;
  if (initialized) return;
  if (VIPS_INIT("discourse_image_processing") != 0) raise_vips();

  /* Avoid libvips operations that are explicitly tagged as unsafe for
   * untrusted input. Also block ImageMagick-backed loaders by class name;
   * this gem uses explicit native libvips loaders and should never fall back
   * to ImageMagick delegates. */
  vips_block_untrusted_set(TRUE);
  vips_operation_block_set("VipsForeignLoadMagick", TRUE);
  vips_operation_block_set("VipsForeignLoadMagick6", TRUE);
  vips_operation_block_set("VipsForeignLoadMagick7", TRUE);

  /* Keep the embedded path predictable and bounded. Callers that want harder
   * isolation should run this gem inside a sandboxed worker process. */
  vips_concurrency_set(1);
  vips_cache_set_max(0);
  vips_cache_set_max_mem(0);
  vips_cache_set_max_files(0);
  initialized = 1;
}

static VipsImage *load_explicit(const char *path, const char **fmt_out) {
  init_vips_once();
  const char *fmt = normalized_format(extname(path));
  if (!fmt) rb_raise(eUnsupported, "unsupported input format");

  VipsImage *image = NULL;
  int rc = -1;
  if (strcmp(fmt, "jpg") == 0) {
    rc = vips_jpegload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  } else if (strcmp(fmt, "png") == 0) {
    rc = vips_pngload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  } else if (strcmp(fmt, "webp") == 0) {
    rc = vips_webpload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  } else if (strcmp(fmt, "heic") == 0 || strcmp(fmt, "avif") == 0) {
    rc = vips_heifload(path, &image,
      "access", VIPS_ACCESS_SEQUENTIAL,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL);
  }

  if (rc != 0 || image == NULL) raise_vips();
  *fmt_out = fmt;
  return image;
}

static void validate_pixels_or_raise(VipsImage *image, VALUE max_pixels_val) {
  if (NIL_P(max_pixels_val)) return;
  long long max_pixels = NUM2LL(max_pixels_val);
  if (max_pixels <= 0) return;
  long long pixels = (long long)image->Xsize * (long long)image->Ysize;
  if (pixels > max_pixels) {
    rb_raise(eLimit, "image has %lld pixels, exceeds %lld", pixels, max_pixels);
  }
}

static int save_explicit(VipsImage *image, const char *path, const char *fmt, int quality) {
  if (strcmp(fmt, "jpg") == 0) {
    return vips_jpegsave(image, path,
      "Q", quality,
      "interlace", FALSE,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  } else if (strcmp(fmt, "png") == 0) {
    return vips_pngsave(image, path,
      "compression", 6,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  } else if (strcmp(fmt, "webp") == 0) {
    return vips_webpsave(image, path,
      "Q", quality,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  } else if (strcmp(fmt, "avif") == 0) {
    return vips_heifsave(image, path,
      "Q", quality,
      "compression", VIPS_FOREIGN_HEIF_COMPRESSION_AV1,
      "keep", VIPS_FOREIGN_KEEP_NONE,
      NULL);
  }
  rb_raise(eUnsupported, "unsupported output format");
}

static VALUE rb_probe(VALUE self, VALUE path_val) {
  Check_Type(path_val, T_STRING);
  double start = now_ms();
  const char *fmt = NULL;
  VipsImage *image = load_explicit(StringValueCStr(path_val), &fmt);

  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("format")), rb_str_new_cstr(fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("width")), INT2NUM(image->Xsize));
  rb_hash_aset(hash, ID2SYM(rb_intern("height")), INT2NUM(image->Ysize));
  rb_hash_aset(hash, ID2SYM(rb_intern("duration_ms")), DBL2NUM(now_ms() - start));
  g_object_unref(image);
  return hash;
}

static VALUE rb_thumbnail(VALUE self, VALUE input_val, VALUE output_val, VALUE width_val, VALUE height_val, VALUE format_val, VALUE quality_val, VALUE max_pixels_val) {
  Check_Type(input_val, T_STRING);
  Check_Type(output_val, T_STRING);
  Check_Type(format_val, T_STRING);
  int width = NUM2INT(width_val);
  int height = NUM2INT(height_val);
  int quality = NUM2INT(quality_val);
  const char *out_fmt = normalized_format(StringValueCStr(format_val));
  if (!out_fmt || strcmp(out_fmt, "heic") == 0) rb_raise(eUnsupported, "unsupported output format");

  double start = now_ms();
  const char *input_fmt = NULL;
  VipsImage *in = load_explicit(StringValueCStr(input_val), &input_fmt);
  validate_pixels_or_raise(in, max_pixels_val);

  VipsImage *rot = NULL;
  if (vips_autorot(in, &rot, NULL) != 0) {
    g_object_unref(in);
    raise_vips();
  }

  VipsImage *thumb = NULL;
  if (vips_thumbnail_image(rot, &thumb, width,
      "height", height,
      "size", VIPS_SIZE_BOTH,
      "crop", VIPS_INTERESTING_CENTRE,
      "fail_on", VIPS_FAIL_ON_ERROR,
      NULL) != 0) {
    g_object_unref(rot);
    g_object_unref(in);
    raise_vips();
  }

  if (save_explicit(thumb, StringValueCStr(output_val), out_fmt, quality) != 0) {
    g_object_unref(thumb);
    g_object_unref(rot);
    g_object_unref(in);
    raise_vips();
  }

  VALUE hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("input_format")), rb_str_new_cstr(input_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("output_format")), rb_str_new_cstr(out_fmt));
  rb_hash_aset(hash, ID2SYM(rb_intern("width")), INT2NUM(thumb->Xsize));
  rb_hash_aset(hash, ID2SYM(rb_intern("height")), INT2NUM(thumb->Ysize));
  rb_hash_aset(hash, ID2SYM(rb_intern("duration_ms")), DBL2NUM(now_ms() - start));

  g_object_unref(thumb);
  g_object_unref(rot);
  g_object_unref(in);
  return hash;
}

void Init_discourse_image_processing_native(void) {
  mDIP = rb_define_module("DiscourseImageProcessing");
  eError = rb_const_get(mDIP, rb_intern("Error"));
  eUnsupported = rb_const_get(mDIP, rb_intern("UnsupportedFormatError"));
  eInvalid = rb_const_get(mDIP, rb_intern("InvalidImageError"));
  eLimit = rb_const_get(mDIP, rb_intern("LimitError"));
  mNative = rb_define_module_under(mDIP, "Native");
  rb_define_singleton_method(mNative, "probe", rb_probe, 1);
  rb_define_singleton_method(mNative, "thumbnail", rb_thumbnail, 7);
}
