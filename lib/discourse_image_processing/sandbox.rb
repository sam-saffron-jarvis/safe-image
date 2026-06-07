# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"

module DiscourseImageProcessing
  module Sandbox
    module_function

    DEFAULT_RLIMITS = {
      cpu_seconds: 30,
      memory_bytes: 2 * 1024 * 1024 * 1024,
      file_size_bytes: 256 * 1024 * 1024,
      open_files: 256
    }.freeze

    def available?
      require "landlock"
      Landlock::SafeExec.supported?
    rescue LoadError
      false
    end

    def capture_command!(argv, read:, write:, timeout: Runner::DEFAULT_TIMEOUT, env: Runner::SAFE_ENV, rlimits: DEFAULT_RLIMITS)
      require "landlock"

      result = Landlock::SafeExec.capture!(
        *argv.map(&:to_s),
        read: existing_paths([*Landlock::SafeExec.default_read_paths, *runtime_read_paths, *read]),
        write: existing_paths(write),
        execute: existing_paths([*Landlock::SafeExec.default_execute_paths, File.dirname(RbConfig.ruby)]),
        env: env,
        inherit_env: false,
        timeout: timeout,
        rlimits: rlimits,
        seccomp_deny_network: true,
        max_output_bytes: 512 * 1024,
        truncate_output: false
      )
      [result.stdout, result.stderr]
    rescue LoadError
      Runner.run!(argv, timeout: timeout, env: env)
    rescue Landlock::SafeExec::CommandError => e
      raise CommandError.new(
        "sandboxed command failed",
        command: argv,
        status: e.status&.exitstatus,
        stdout: e.stdout,
        stderr: e.stderr
      )
    end

    def thumbnail(request)
      run_worker!("thumbnail", request)
    end

    def run_worker!(operation, request)
      require "landlock"
      payload = JSON.dump({ operation: operation, request: request })
      code = <<~'RUBY'
        require "json"
        require "discourse_image_processing"
        payload = JSON.parse(ARGV.fetch(0), symbolize_names: true)
        req = payload.fetch(:request)
        case payload.fetch(:operation)
        when "thumbnail"
          result = DiscourseImageProcessing.thumbnail(
            input: req.fetch(:input),
            output: req.fetch(:output),
            width: req.fetch(:width),
            height: req.fetch(:height),
            format: req[:format],
            quality: req.fetch(:quality),
            max_pixels: req[:max_pixels],
            backend: req.fetch(:backend).to_sym,
            optimize: req.fetch(:optimize),
            optimize_mode: req.fetch(:optimize_mode).to_sym,
            execution: :inline
          )
          puts JSON.dump(result.to_h)
        else
          abort "unknown operation"
        end
      RUBY

      input = request.fetch(:input)
      output = request.fetch(:output)
      stdout, = Landlock::SafeExec.capture!(
        RbConfig.ruby,
        "-I#{File.expand_path("../../", __dir__)}",
        "-rjson",
        "-e",
        code,
        payload,
        read: existing_paths([*Landlock::SafeExec.default_read_paths, *runtime_read_paths, input, File.dirname(output), Dir.tmpdir]),
        write: existing_paths([File.dirname(output), Dir.tmpdir]),
        execute: existing_paths([*Landlock::SafeExec.default_execute_paths, File.dirname(RbConfig.ruby)]),
        env: Runner::SAFE_ENV.merge(
          "GEM_HOME" => ENV["GEM_HOME"].to_s,
          "GEM_PATH" => ENV["GEM_PATH"].to_s,
          "RUBYLIB" => $LOAD_PATH.select { |p| p && File.directory?(p) }.join(File::PATH_SEPARATOR)
        ),
        inherit_env: false,
        timeout: Runner::DEFAULT_TIMEOUT,
        rlimits: DEFAULT_RLIMITS,
        seccomp_deny_network: true,
        max_output_bytes: 512 * 1024,
        truncate_output: false
      )
      symbolize(JSON.parse(stdout))
    rescue LoadError
      nil
    rescue Landlock::SafeExec::CommandError => e
      raise CommandError.new(
        "sandboxed worker failed",
        command: [RbConfig.ruby, "-e", "..."],
        status: e.status&.exitstatus,
        stdout: e.stdout,
        stderr: e.stderr
      )
    end

    def runtime_read_paths
      paths = []
      paths.concat(Gem.path) if defined?(Gem)
      paths.concat($LOAD_PATH.select { |path| path && path != "." })
      paths << RbConfig::CONFIG["rubylibdir"]
      paths << RbConfig::CONFIG["rubyarchdir"]
      paths << RbConfig::CONFIG["sitearchdir"]
      paths << RbConfig::CONFIG["vendorarchdir"]
      paths << File.dirname(RbConfig.ruby)
      paths
    end

    def existing_paths(paths)
      paths.flatten.compact.map(&:to_s).reject(&:empty?).select { |path| File.exist?(path) }.uniq
    end

    def symbolize(hash)
      hash.transform_keys(&:to_sym)
    end
  end
end
