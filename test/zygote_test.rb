# frozen_string_literal: true

require "fileutils"
require_relative "test_helper"

module SafeImage
  # Lifecycle of the persistent sandbox worker. The operation results
  # themselves are covered by SandboxIntegrationTest, which runs every public
  # API through the zygote.
  class ZygoteTest < TestCase
    def setup
      super
      skip "Landlock::SafeExec unavailable" unless SafeImage.sandbox_available?
      skip "zygote disabled" unless Zygote.enabled?
      configure_safe_image(landlock: true)
    end

    def teardown
      ENV.delete("SAFE_IMAGE_ZYGOTE_IDLE_SECONDS")
      Zygote.shutdown!
      super
    end

    def test_reuses_the_zygote_across_operations
      first = optimized_copy("reuse-1.jpg")
      pid = Zygote.pid
      refute_nil pid
      assert zygote_alive?(pid)

      second = optimized_copy("reuse-2.jpg")
      assert_equal pid, Zygote.pid
      assert_equal first, second, "same input must optimize identically through one zygote"
    end

    def test_reconfigure_respawns_the_zygote
      optimized_copy("reconf-1.jpg")
      pid = Zygote.pid

      configure_safe_image(backend: :imagemagick, landlock: true)
      refute_nil pid
      # kill is delivered synchronously but the detach thread reaps the zombie
      # asynchronously, so allow a moment before asserting it is gone
      assert deadline_wait { !zygote_alive?(pid) }, "configure! must shut the stale zygote down"

      optimized_copy("reconf-2.jpg")
      refute_equal pid, Zygote.pid
    end

    def test_recovers_when_the_zygote_is_killed
      optimized_copy("kill-1.jpg")
      pid = Zygote.pid
      Process.kill("KILL", pid)
      assert deadline_wait { !zygote_alive?(pid) }, "killed zygote did not exit"

      optimized_copy("kill-2.jpg")
      refute_equal pid, Zygote.pid
    end

    # A worker checked out when configure!/shutdown! lands must NOT be returned
    # to the pool: it was booted under the old backend/max_pixels, and reusing
    # it would serve operations under stale configuration (part of the security
    # boundary). White-box because the race is otherwise timing-dependent.
    def test_reconfigure_retires_a_checked_out_worker
      worker = Zygote.checkout
      pid = worker.pid
      assert zygote_alive?(pid)
      assert_equal 1, Zygote.pool_size

      Zygote.shutdown! # what configure! triggers, landing while the op is "in flight"

      Zygote.checkin(worker) # the in-flight operation completes and returns its worker
      assert_equal 0, Zygote.pool_size, "stale worker was counted into the new pool"
      refute_includes Zygote.pids, pid, "stale worker was returned to the idle pool"
      assert deadline_wait { !zygote_alive?(pid) }, "stale worker was not killed"

      optimized_copy("post-reconfigure.jpg")
      refute_equal pid, Zygote.pid, "operation reused the retired worker"
      assert_equal 1, Zygote.pool_size
    end

    def test_idle_zygote_exits_and_respawns
      ENV["SAFE_IMAGE_ZYGOTE_IDLE_SECONDS"] = "0.2"
      Zygote.shutdown!

      optimized_copy("idle-1.jpg")
      pid = Zygote.pid
      assert deadline_wait { !zygote_alive?(pid) }, "idle zygote did not exit"

      optimized_copy("idle-2.jpg")
      refute_equal pid, Zygote.pid
    end

    def test_concurrent_operations_use_multiple_workers
      threads = 4
      barrier = Queue.new

      results = threads.times.map do |i|
        Thread.new do
          jpg = tmp_path("concurrent-#{i}.jpg")
          FileUtils.cp(JPG, jpg)
          # stagger nothing: hammer simultaneously so the pool must grow
          barrier.pop
          SafeImage.optimize(jpg)
          File.binread(jpg)
        end
      end
      threads.times { barrier << :go }
      payloads = results.map(&:value)

      assert_equal 1, payloads.uniq.size, "every worker must produce identical output"
      assert_operator Zygote.pool_size, :>, 1, "concurrent load did not grow the pool past one worker"
      assert_operator Zygote.pool_size, :<=, Zygote.max_workers
    end

    # A discarded worker (killed mid-op, e.g. on timeout) must free its pool
    # slot so the cap is a steady-state ceiling, not a high-water mark that
    # eventually deadlocks.
    def test_killed_worker_frees_its_pool_slot
      optimized_copy("slot-1.jpg")
      assert_equal 1, Zygote.pool_size
      Process.kill("KILL", Zygote.pid)
      deadline_wait { Zygote.pids.none? { |p| zygote_alive?(p) } }

      optimized_copy("slot-2.jpg")
      assert_equal 1, Zygote.pool_size, "pool slot was not reclaimed after the worker died"
    end

    def test_pool_is_capped_at_max_workers
      ENV["SAFE_IMAGE_ZYGOTE_WORKERS"] = "2"
      Zygote.shutdown!

      threads = 6
      barrier = Queue.new
      results = threads.times.map do |i|
        Thread.new do
          jpg = tmp_path("capped-#{i}.jpg")
          FileUtils.cp(JPG, jpg)
          barrier.pop
          SafeImage.optimize(jpg)
          :ok
        end
      end
      threads.times { barrier << :go }
      assert_equal [:ok] * threads, results.map(&:value)
      assert_operator Zygote.pool_size, :<=, 2, "pool exceeded the configured cap"
    ensure
      ENV.delete("SAFE_IMAGE_ZYGOTE_WORKERS")
    end

    # The generous idle window is safe because a zygote never outlives its
    # parent: parent exit closes the request pipe and the zygote exits on EOF.
    def test_zygote_exits_when_its_parent_does
      jpg = tmp_path("orphan.jpg")
      FileUtils.cp(JPG, jpg)
      script = <<~RUBY
        require "safe_image"
        SafeImage.configure!(backend: :vips, landlock: true)
        SafeImage.optimize(#{jpg.dump})
        puts SafeImage::Zygote.pid
      RUBY
      out = IO.popen([RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-e", script], &:read)
      assert $CHILD_STATUS&.success? || $?.success?, "parent script failed: #{out}"
      zygote_pid = Integer(out[/\d+/])

      assert deadline_wait { !zygote_alive?(zygote_pid) },
             "zygote #{zygote_pid} outlived its exited parent"
    end

    def test_zygote_output_matches_unsandboxed_byte_for_byte
      sandboxed = optimized_copy("equiv-sandboxed.jpg")

      configure_safe_image(landlock: false)
      unsandboxed = optimized_copy("equiv-inline.jpg")

      assert_equal unsandboxed, sandboxed
    end

    private

    def optimized_copy(name)
      path = tmp_path(name)
      FileUtils.cp(JPG, path)
      SafeImage.optimize(path)
      File.binread(path)
    end

    def zygote_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def deadline_wait(seconds = 3)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      true
    end
  end
end
