# frozen_string_literal: true

require "open3"
require_relative "test_helper"

module SafeImage
  # Hostile input is routine for this gem; libvips' GLib warnings about it
  # must not litter stderr (test output, production logs). Failures still
  # surface as exceptions. SAFE_IMAGE_VIPS_WARNINGS=1 restores the warnings.
  #
  # Which inputs make libvips warn varies by version (8.15 rejects the fake
  # PNG without a peep; 8.18 warns twice), so the script also raises a
  # synthetic warning through the real GLib logging pipeline in the VIPS
  # domain — present on every supported version, it keeps both assertions
  # deterministic while still exercising the real handler vips_init installs.
  class VipsLogSilenceTest < TestCase
    SCRIPT = <<~'RUBY'
      require "safe_image"
      begin
        # configure! triggers vips_init, which installs the log handler.
        SafeImage.configure!(backend: :vips, landlock: false)
        SafeImage.probe(ARGV[0])
      rescue SafeImage::InvalidImageError
        print "rejected"
      end

      require "fiddle"
      g_log = Fiddle::Function.new(
        Fiddle.dlopen("libvips.so.42")["g_log"],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VARIADIC],
        Fiddle::TYPE_VOID
      )
      g_log_level_warning = 1 << 4
      g_log.call("VIPS", g_log_level_warning, "%s", Fiddle::TYPE_VOIDP, "synthetic warning")
    RUBY

    def test_rejected_input_does_not_write_vips_warnings_to_stderr
      stdout, stderr, = run_probe({})

      assert_equal "rejected", stdout
      refute_match(/VIPS-WARNING/, stderr, "GLib warnings leaked to stderr")
    end

    def test_opt_out_keeps_the_warnings
      _stdout, stderr, = run_probe({ "SAFE_IMAGE_VIPS_WARNINGS" => "1" })

      assert_match(/VIPS-WARNING \*\*.*synthetic warning/, stderr)
    end

    private

    def run_probe(env)
      fake = write_tmp("fake.png", "not a png")
      Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", SCRIPT, fake)
    end
  end
end
