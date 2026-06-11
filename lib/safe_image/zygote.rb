# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

module SafeImage
  # Raised when a worker's request/reply channel breaks (closed or broken pipe,
  # truncated reply, protocol garbage, or a reply-deadline overrun) as opposed
  # to the operation itself failing. It is a CommandError so callers catching
  # the documented error still handle it, but the pool treats it specially:
  # the worker is discarded, never returned to the idle set. Process liveness
  # is the wrong reuse signal — a worker can be alive with a dead pipe (e.g. a
  # concurrent reconfigure closed it) — so channel health drives the decision.
  class WorkerBroken < CommandError; end

  # Pool of persistent pre-booted sandbox workers. The exec-per-operation
  # worker in Sandbox.run_worker! pays ~55ms of Ruby boot + requires (plus
  # ~27ms of libvips dlopen/init on the vips backend) on every call; a zygote
  # pays it once, then serves each operation from a fork (~1ms) that sandboxes
  # ITSELF before touching any untrusted input. After IDLE_SECONDS without work
  # a zygote exits on its own, so no resident process outlives a burst.
  #
  # Concurrency: each zygote serves one operation at a time over its pipe (its
  # forked child does the work, but replies stream back over one pipe). To let
  # N threads run sandboxed operations at once — the exec worker had unbounded
  # per-thread concurrency, a single zygote would serialise them — workers are
  # pooled. A call checks out an idle worker (or spawns one, up to
  # MAX_WORKERS), and returns it when done; offered concurrency past the cap
  # blocks until a worker frees, which also bounds concurrent libvips memory.
  #
  # Trust model (same as the exec worker): a zygote is a fresh Ruby process
  # booted with a scrubbed env that only ever parses requests from the parent —
  # never untrusted bytes. Untrusted input is only opened in the forked
  # grandchild, after it has applied rlimits, a per-operation Landlock policy
  # (filesystem allowlist; all TCP denied via a handled-but-unmatchable port
  # rule on ABI >= 4; abstract-unix-socket and signal scopes on ABI >= 6), and
  # — where the landlock gem exposes it — the helper's deny-all-network seccomp
  # filter (closing the non-TCP/UDP gap the in-process Landlock policy alone
  # leaves open). Forking is sound because a zygote never runs an operation
  # itself: libvips is initialised but quiescent (zero native threads) at every
  # fork.
  module Zygote
    module_function

    # How long an idle zygote lingers before exiting. Idling is cheap — ~16MB
    # private memory (the ~48MB RSS is mostly shared library pages), flat
    # across operations, zero CPU (blocked in select) — and a parent that
    # exits takes its zygotes with it immediately via stdin EOF, so the window
    # is generous. Overridable via the SAFE_IMAGE_ZYGOTE_IDLE_SECONDS env var.
    IDLE_SECONDS = 300

    # Max concurrent sandboxed operations (= resident workers under load).
    # Overridable via SAFE_IMAGE_ZYGOTE_WORKERS. The cap is backpressure: a
    # burst of 50 uploads runs at most this many libvips decodes at once.
    DEFAULT_MAX_WORKERS = 8

    SPAWN_TIMEOUT = 30
    # The parent's reply deadline is the worker's own operation timeout plus
    # this grace: the worker enforces Runner::DEFAULT_TIMEOUT around the forked
    # child (killing it and replying), and the grace covers the worker's reply
    # serialization and child reaping so the parent only gives up — and kills
    # the worker — when the worker itself has wedged, not merely when the
    # operation ran long.
    RESPONSE_GRACE = 10
    MAX_RESPONSE_BYTES = 512 * 1024

    # generation: the pool generation a worker was born into; shutdown!/fork
    # bump the generation so a worker checked out under the old config is
    # retired (never re-pooled) when it returns. owner_pid: the process that
    # spawned it, so a worker inherited across fork is never killed by the
    # child (it belongs to the parent).
    # tmproot: a parent-created directory the worker puts its per-operation
    # tmpdirs under. The worker removes it on graceful exit (at_exit); the
    # parent removes it when it kills the worker, so a SIGKILL mid-operation
    # (where the worker cannot clean up) does not leak the op's tmpdir.
    Worker = Struct.new(:pid, :stdin, :stdout, :last_used, :generation, :owner_pid, :tmproot)

    @mutex = Mutex.new
    @free = ConditionVariable.new
    @idle = []        # checked-in Workers of the current generation, MRU last
    @count = 0        # live workers of the current generation: idle + checked out
    @generation = 0   # bumped by shutdown!/fork to retire outstanding workers
    @key = nil        # [pid, backend, max_pixels] the pool was built for

    def enabled?
      ENV["SAFE_IMAGE_ZYGOTE"] != "0" && Process.respond_to?(:fork)
    end

    def max_workers
      n = ENV["SAFE_IMAGE_ZYGOTE_WORKERS"].to_i
      n.positive? ? n : DEFAULT_MAX_WORKERS
    end

    # Exposed for tests/diagnostics: the idle worker that a serial caller keeps
    # reusing (nil mid-operation or when the pool is empty).
    def pid
      @mutex.synchronize { @idle.last&.pid }
    end

    def pids
      @mutex.synchronize { @idle.map(&:pid) }
    end

    def pool_size
      @mutex.synchronize { @count }
    end

    def shutdown!
      @mutex.synchronize do
        @idle.each { |w| close_worker(w, kill: w.owner_pid == Process.pid) }
        @idle.clear
        @count = 0
        @key = nil
        # Retire any worker still checked out: its generation no longer matches,
        # so checkin/discard will close it instead of returning it to the pool.
        # This is what stops a worker booted under the old config from serving
        # an operation after a reconfigure.
        @generation += 1
        @free.broadcast
      end
    end

    def call!(operation, request)
      payload = JSON.dump(
        operation: operation.to_s,
        request: Sandbox.deep_encode_symbols(request),
        paths: Sandbox.sandbox_paths(request, operation),
        timeout: Runner::DEFAULT_TIMEOUT
      )

      attempts = 0
      begin
        attempts += 1
        worker = checkout
        # Every path below returns the worker to the pool exactly once
        # (checkin if reusable, discard otherwise) so a slot is never leaked.
        begin
          worker.stdin.puts(payload)
        rescue Errno::EPIPE, IOError
          # The channel is gone before the request landed — the worker
          # idle-exited, or a concurrent reconfigure closed its pipe. Nothing
          # ran, so discard it and respawn once, transparently.
          discard(worker)
          retry if attempts == 1
          raise CommandError.new("sandbox zygote is not accepting requests", command: ["zygote"])
        rescue StandardError
          discard(worker)
          raise
        end

        begin
          reply = read_reply(worker)
        rescue WorkerBroken
          # The channel broke (closed/broken pipe, truncated reply, protocol
          # error, deadline). The worker is unusable regardless of whether its
          # process is still alive — drop it, never return it to the pool.
          discard(worker)
          raise
        rescue StandardError
          # The worker replied with an operation failure (oxipng exited 1, ...)
          # and is otherwise healthy, so return it to the pool for reuse.
          checkin(worker)
          raise
        end
        checkin(worker)
        reply
      end
    end

    # Block until a worker is available, spawning one (outside the lock) when
    # the pool is below the cap.
    def checkout
      loop do
        gen = nil
        @mutex.synchronize do
          drop_foreign_pool!
          while (w = @idle.pop)
            return w if worker_usable?(w)

            drop_worker(w)
          end
          if @count < max_workers
            @count += 1
            @key ||= pool_key
            gen = @generation
          else
            @free.wait(@mutex)
          end
        end
        next unless gen

        begin
          return spawn_worker(gen)
        rescue StandardError
          @mutex.synchronize do
            # Release the reserved slot, but only against the generation it was
            # reserved under — a concurrent shutdown! may have zeroed @count.
            @count -= 1 if gen == @generation
            @free.signal
          end
          raise
        end
      end
    end

    def checkin(worker)
      @mutex.synchronize do
        if worker.generation == @generation
          worker.last_used = monotonic
          @idle.push(worker)
          @free.signal
        else
          # Retired by a shutdown!/reconfigure while it was checked out.
          drop_worker(worker)
        end
      end
    end

    def discard(worker)
      @mutex.synchronize { drop_worker(worker) }
    end

    # Close a worker and release its pool slot. The slot is only counted
    # against the current generation — a worker retired by shutdown!/fork
    # belongs to a generation whose @count was already zeroed, so its return
    # must not push @count negative. A worker spawned by another process
    # (inherited across fork) is closed but never killed.
    def drop_worker(worker)
      close_worker(worker, kill: worker.owner_pid == Process.pid)
      @count -= 1 if worker.generation == @generation
      @free.signal
    end

    # A pool inherited across fork belongs to the parent: drop our copies of
    # its pipes without killing the parent's processes, retire the generation
    # (so a worker checked out across the fork is not reused), and rebuild
    # lazily.
    def drop_foreign_pool!
      return unless @key && @key[0] != Process.pid

      @idle.each { |w| close_worker(w, kill: false) }
      @idle.clear
      @count = 0
      @key = nil
      @generation += 1
    end

    def pool_key
      config = SafeImage.config
      [Process.pid, config.backend, config.max_pixels]
    end

    def worker_usable?(worker)
      worker.generation == @generation &&
        alive?(worker.pid) &&
        (monotonic - worker.last_used) < idle_seconds
    end

    # Falls back to the default on a missing, non-numeric, or non-positive
    # value rather than raising or letting a negative reach the worker's
    # IO.select idle timeout (which would raise there).
    def idle_seconds
      raw = ENV["SAFE_IMAGE_ZYGOTE_IDLE_SECONDS"]
      return IDLE_SECONDS unless raw

      value = begin
        Float(raw)
      rescue ArgumentError, TypeError
        nil
      end
      value&.positive? ? value : IDLE_SECONDS
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def spawn_worker(generation)
      require "landlock"
      config = SafeImage.config
      tmproot = Dir.mktmpdir("safe-image-zygote-")
      boot = JSON.dump(
        config: { backend: config.backend, max_pixels: config.max_pixels },
        idle_seconds: idle_seconds,
        tmproot: tmproot,
        rlimits: Sandbox::DEFAULT_RLIMITS,
        execute: Sandbox.existing_paths([*Landlock::SafeExec.default_execute_paths, File.dirname(RbConfig.ruby)]),
        max_response_bytes: MAX_RESPONSE_BYTES
      )

      env = Runner.command_env(Dir.tmpdir).merge(
        "SAFE_IMAGE_SANDBOX_CHILD" => "1",
        "GEM_HOME" => ENV["GEM_HOME"].to_s,
        "GEM_PATH" => ENV["GEM_PATH"].to_s,
        "RUBYLIB" => $LOAD_PATH.select { |p| p && File.directory?(p) }.join(File::PATH_SEPARATOR)
      )

      in_r, in_w = IO.pipe
      out_r, out_w = IO.pipe
      pid = Process.spawn(
        env,
        RbConfig.ruby,
        "-I#{File.expand_path("../../", __dir__)}",
        "-rjson",
        "-e",
        ZYGOTE_PROGRAM,
        boot,
        in: in_r, out: out_w, unsetenv_others: true, pgroup: true
      )
      Process.detach(pid)
      in_r.close
      out_w.close
      in_w.sync = true

      worker = Worker.new(pid, in_w, out_r, monotonic, generation, Process.pid, tmproot)
      ready = read_line(worker, SPAWN_TIMEOUT)
      raise CommandError.new("sandbox zygote failed to boot", command: ["zygote"]) unless ready && JSON.parse(ready)["ready"]

      worker
    rescue StandardError
      if worker
        close_worker(worker, kill: true)
      else
        in_w&.close rescue nil
        out_r&.close rescue nil
        FileUtils.remove_entry(tmproot) if tmproot && File.directory?(tmproot)
      end
      raise
    end

    def read_reply(worker)
      line = read_line(worker, Runner::DEFAULT_TIMEOUT + RESPONSE_GRACE)
      raise WorkerBroken.new("sandbox zygote died mid-operation", command: ["zygote"]) if line.nil?

      reply = JSON.parse(line, symbolize_names: true)
      unless reply[:ok]
        # The worker ran the operation and reported its failure: it is healthy
        # and reusable, so this is a plain CommandError, not WorkerBroken.
        raise CommandError.new(
          "sandboxed operation failed: #{reply[:error].to_s[0, 2000]}",
          command: ["zygote"],
          status: reply[:status],
          stderr: reply[:stderr].to_s
        )
      end
      Sandbox.decode_payload(JSON.parse(reply.fetch(:body), symbolize_names: true))
    rescue JSON::ParserError => e
      kill_worker(worker)
      raise WorkerBroken.new("sandbox zygote protocol error: #{e.message}", command: ["zygote"])
    end

    # Blocking line read with a deadline. Every channel-level failure — overrun,
    # oversize, or the stdout being closed under us by a concurrent
    # reconfigure — raises WorkerBroken so the caller discards the worker rather
    # than returning a dead pipe to the pool.
    def read_line(worker, timeout)
      deadline = monotonic + timeout
      buffer = +""
      loop do
        remaining = deadline - monotonic
        if remaining <= 0
          kill_worker(worker)
          raise WorkerBroken.new("sandboxed operation timed out", command: ["zygote"])
        end

        chunk =
          begin
            next unless IO.select([worker.stdout], nil, nil, remaining)

            worker.stdout.read_nonblock(65_536, exception: false)
          rescue IOError
            raise WorkerBroken.new("sandbox zygote channel closed", command: ["zygote"])
          end

        case chunk
        when :wait_readable then next
        when nil
          return buffer.empty? ? nil : buffer
        else
          buffer << chunk
          return buffer if buffer.end_with?("\n")
          # 2x: the reply line wraps a body the zygote already caps at
          # MAX_RESPONSE_BYTES, plus JSON escaping overhead.
          if buffer.bytesize > MAX_RESPONSE_BYTES * 2
            kill_worker(worker)
            raise WorkerBroken.new("sandbox zygote response exceeded #{MAX_RESPONSE_BYTES} bytes", command: ["zygote"])
          end
        end
      end
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def kill_worker(worker)
      return unless worker&.pid

      begin
        # Kills the zygote's process group. An idle zygote (no in-flight
        # operation) has no other group members, so this reaps it cleanly. A
        # zygote killed mid-operation does NOT take its active operation child
        # with it this way — that child setpgrp'd into its own group — so the
        # child carries PR_SET_PDEATHSIG=SIGKILL to die when the zygote dies.
        Process.kill("KILL", -worker.pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    def close_worker(worker, kill:)
      kill_worker(worker) if kill
      worker.stdin&.close rescue nil
      worker.stdout&.close rescue nil
      # Only our own workers' tmp roots are ours to remove; an inherited
      # (kill: false) worker's belongs to the parent. A gracefully-exited
      # worker has already removed its own via at_exit; this catches the
      # SIGKILLed-mid-operation case.
      FileUtils.remove_entry(worker.tmproot) if kill && worker.tmproot && File.directory?(worker.tmproot)
    rescue StandardError
      nil
    end

    # The resident process. Boots the gem once, then serves requests from
    # stdin: one fork per request, sandboxed in the fork, one JSON reply line
    # per request on stdout. Exits when idle or when the parent closes stdin.
    ZYGOTE_PROGRAM = <<~'RUBY'
      require "safe_image"
      require "landlock"
      require "tmpdir"
      require "fileutils"

      def deep_symbolize(value)
        case value
        when Hash
          return value[:__sym__].to_sym if value.size == 1 && value[:__sym__].is_a?(String)
          value.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
        when Array
          value.map { |v| deep_symbolize(v) }
        else
          value
        end
      end

      ALLOWED_OPERATIONS = %w[
        probe thumbnail type size dimensions info orientation dominant_color optimize resize crop downsize convert convert_to_jpeg fix_orientation
        convert_favicon_to_png frame_count animated? letter_avatar optimize_image! sanitize_svg!
      ]

      boot = JSON.parse(ARGV.fetch(0), symbolize_names: true)
      config = boot.fetch(:config)
      SafeImage.configure!(backend: config.fetch(:backend).to_sym, landlock: false, max_pixels: config.fetch(:max_pixels))

      idle = boot.fetch(:idle_seconds)
      rlimits = boot.fetch(:rlimits)
      execute_paths = boot.fetch(:execute)
      max_bytes = boot.fetch(:max_response_bytes)
      tmproot = boot.fetch(:tmproot)
      read_defaults = Landlock::SafeExec.default_read_paths +
        SafeImage::Sandbox.runtime_read_paths

      # Runs on graceful exit (idle timeout / parent stdin EOF) but not in the
      # op child, which leaves via exit! — so only the long-lived zygote cleans
      # its tmp root, and the parent covers the SIGKill case.
      at_exit { FileUtils.remove_entry(tmproot) if File.directory?(tmproot) rescue nil }

      zygote_pid = Process.pid

      # libc prctl(2) for PR_SET_PDEATHSIG, so an operation child dies with the
      # zygote even after it setpgrp's out of the zygote's process group (where
      # a parent-side group-kill can no longer reach it). nil if unavailable;
      # the CPU rlimit remains a backstop either way.
      prctl =
        begin
          require "fiddle"
          Fiddle::Function.new(
            Fiddle::Handle::DEFAULT["prctl"],
            [Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG],
            Fiddle::TYPE_INT
          )
        rescue StandardError
          nil
        end
      pr_set_pdeathsig = 1
      sigkill = 9

      $stdout.sync = true
      $stdout.puts(JSON.dump(ready: true, pid: Process.pid))

      loop do
        exit 0 unless IO.select([$stdin], nil, nil, idle)
        line = $stdin.gets
        exit 0 if line.nil?

        req = JSON.parse(line, symbolize_names: true)
        operation = req.fetch(:operation)
        raise ArgumentError, "unsupported sandbox operation: #{operation}" unless ALLOWED_OPERATIONS.include?(operation)

        tmpdir = Dir.mktmpdir("op-", tmproot)
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe

        pid = fork do
          out_r.close
          err_r.close
          $stdin.reopen(File::NULL)
          $stdout.reopen(err_w)
          $stderr.reopen(err_w)
          Process.setpgrp # own group, so the zygote's per-op timeout kill (-pid) reaps tools too

          # Die if the zygote dies: once we setpgrp out of its group a
          # parent-side group-kill can no longer reach us, so request a SIGKILL
          # on the zygote's death. PR_SET_PDEATHSIG only fires on a *future*
          # parent death, so re-check the zygote is still our parent to close
          # the fork→prctl race where it died in between.
          prctl&.call(pr_set_pdeathsig, sigkill, 0, 0, 0)
          exit!(1) unless Process.ppid == zygote_pid

          ENV["TMPDIR"] = tmpdir
          ENV["HOME"] = tmpdir
          ENV["XDG_CACHE_HOME"] = tmpdir
          ENV["MAGICK_TEMPORARY_PATH"] = tmpdir

          Process.setrlimit(:CPU, rlimits.fetch(:cpu_seconds))
          Process.setrlimit(:AS, rlimits.fetch(:memory_bytes))
          Process.setrlimit(:FSIZE, rlimits.fetch(:file_size_bytes))
          Process.setrlimit(:NOFILE, rlimits.fetch(:open_files))

          abi = Landlock.abi_version
          # Port 1 is never used: handling the TCP rights with an unmatchable
          # rule denies all TCP connect/bind.
          net = abi >= 4 ? { connect_tcp: [1], bind_tcp: [1] } : {}
          scope = abi >= 6 ? %i[abstract_unix_socket signal] : []
          existing = ->(paths) { paths.compact.map(&:to_s).reject(&:empty?).select { |p| File.exist?(p) }.uniq }
          Landlock.restrict!(
            read: existing.call(read_defaults + req.dig(:paths, :read) + [tmpdir]),
            write: existing.call(req.dig(:paths, :write) + [tmpdir]),
            execute: existing.call(execute_paths),
            scope: scope,
            **net
          )
          # landlock >= the version that ships it: the helper's deny-all
          # seccomp filter, self-applied — closes the UDP gap the in-process
          # Landlock policy alone leaves open.
          Landlock.seccomp_deny_network! if Landlock.respond_to?(:seccomp_deny_network!)

          request = deep_symbolize(req.fetch(:request))
          result = SafeImage.__send__(operation, *(request[:args] || []), **(request[:kwargs] || {}))

          body =
            if defined?(SafeImage::Result) && result.is_a?(SafeImage::Result)
              { __type: "Result", data: result.to_h }
            elsif defined?(SafeImage::Info) && result.is_a?(SafeImage::Info)
              { __type: "Info", data: result.to_h }
            else
              { __type: "Value", data: result }
            end
          out_w.write(JSON.dump(body))
          out_w.close
          exit!(0)
        rescue Exception => e # rubocop:disable Lint/RescueException -- the fork must never escape into the zygote loop
          err_w.write("#{e.class}: #{e.message}") rescue nil
          exit!(1)
        end

        out_w.close
        err_w.close

        body = +""
        stderr = +""
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + req.fetch(:timeout)
        timed_out = false
        readers = [out_r, err_r]
        until readers.empty?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            timed_out = true
            Process.kill("KILL", -pid) rescue nil
            break
          end
          ready = IO.select(readers, nil, nil, remaining) or next
          ready[0].each do |io|
            chunk = io.read_nonblock(65_536, exception: false)
            if chunk.nil?
              readers.delete(io)
            elsif chunk != :wait_readable
              (io == out_r ? body : stderr) << chunk
              if body.bytesize + stderr.bytesize > max_bytes
                timed_out = false
                Process.kill("KILL", -pid) rescue nil
                readers.clear
                stderr = "operation output exceeded #{max_bytes} bytes"
              end
            end
          end
        end
        _, status = Process.waitpid2(pid)
        out_r.close
        err_r.close
        FileUtils.remove_entry(tmpdir) rescue nil

        if timed_out
          $stdout.puts(JSON.dump(ok: false, error: "operation timed out", stderr: stderr[0, 8192], status: nil))
        elsif status.success? && !body.empty?
          $stdout.puts(JSON.dump(ok: true, body: body))
        else
          detail = stderr.strip
          detail = "exit status #{status.exitstatus.inspect}" if detail.empty?
          $stdout.puts(JSON.dump(ok: false, error: detail[0, 8192], stderr: stderr[0, 8192], status: status.exitstatus))
        end
      end
    RUBY
  end
end
