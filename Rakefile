# frozen_string_literal: true

require "rake/extensiontask"

Rake::ExtensionTask.new("discourse_image_processing_native") do |ext|
  ext.lib_dir = "lib"
  ext.ext_dir = "ext/discourse_image_processing_native"
end

task default: [:compile, :test]

task :test => :compile do
  ruby "-Ilib -I. test/smoke.rb"
  ruby "-Ilib -I. test/compat_smoke.rb"
  ruby "-Ilib -I. test/golden_compat.rb"
  ruby "-Ilib -I. test/imagemagick_parity.rb"
  ruby "-Ilib -I. test/safety_policy.rb"
  ruby "-Ilib -I. test/atomic_sandbox_all.rb"
end
