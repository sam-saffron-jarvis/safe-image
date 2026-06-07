# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "discourse_image_processing"
  spec.version = File.read(File.expand_path("lib/discourse_image_processing/version.rb", __dir__)).match(/VERSION = "([^"]+)"/)[1]
  spec.summary = "Small, secure image processing boundary for Discourse"
  spec.description = "A minimal libvips-backed image processing gem for untrusted uploads. No ruby-vips dependency; calls libvips from a tiny native extension."
  spec.homepage = "https://github.com/sam-saffron-jarvis/discourse-image-processing"
  spec.license = "MIT"
  spec.authors = ["Sam Saffron", "Jarvis"]
  spec.email = ["sam@discourse.org"]
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "ext/**/*.{c,rb}", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/discourse_image_processing_native/extconf.rb"]

  spec.add_runtime_dependency "rexml", "~> 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "homepage_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }
end
