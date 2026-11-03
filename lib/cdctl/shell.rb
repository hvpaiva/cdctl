# frozen_string_literal: true

module Cdctl
  # The one place that starts another program: an argument vector, never a shell string, with a
  # deadline that kills the whole process group.
  class Shell
    class NotAvailable < StandardError; end
    class TimedOut < StandardError; end

    Output = Data.define(:stdout, :stderr, :exit_status) do
      def success? = exit_status&.zero? || false
    end

    DEFAULT_TIMEOUT = 5.0
    CHUNK = 1 << 16
    # A capture of the largest display a game runs on, with room to spare.
    MAX_OUTPUT = 256 * 1024 * 1024

    def initialize(env = {})
      @env = env
    end

    def run(*argv, timeout: DEFAULT_TIMEOUT)
      out_read, out_write = IO.pipe(binmode: true)
      err_read, err_write = IO.pipe(binmode: true)
      pid = Process.spawn(@env, *argv, in: File::NULL, out: out_write, err: err_write, pgroup: true)
      [out_write, err_write].each(&:close)
      finish(pid, out_read, err_read, now + timeout, argv.first)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise NotAvailable, "#{argv.first}: #{e.message.sub(/ - .*\z/m, '')}"
    rescue SignalException
      # Its own process group keeps it out of reach of the signal that just stopped this process.
      kill_group(pid) if pid
      raise
    ensure
      [out_read, out_write, err_read, err_write].compact.reject(&:closed?).each(&:close)
    end

    private

    def finish(pid, out_read, err_read, deadline, name)
      buffers = { out_read => String.new(encoding: Encoding::BINARY),
                  err_read => String.new(encoding: Encoding::BINARY) }
      drain(buffers, pid, deadline, name)
      status = reap(pid, deadline, name)
      Output.new(stdout: buffers[out_read], stderr: buffers[err_read], exit_status: status.exitstatus)
    end

    def drain(buffers, pid, deadline, name)
      open = buffers.keys
      until open.empty?
        ready = IO.select(open, nil, nil, [deadline - now, 0].max)
        abandon(pid, "#{name} did not finish in time") unless ready
        ready.first.each { |io| open.delete(io) if read_some(io, buffers[io]) == :eof }
        abandon(pid, "#{name} wrote more than expected") if buffers.values.sum(&:bytesize) > MAX_OUTPUT
      end
    end

    def read_some(io, buffer)
      chunk = io.read_nonblock(CHUNK, exception: false)
      return :eof if chunk.nil?

      buffer << chunk unless chunk == :wait_readable
      :more
    end

    def reap(pid, deadline, name)
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status

        abandon(pid, "#{name} did not finish in time") if now > deadline
        sleep(0.005)
      end
    end

    def abandon(pid, reason)
      kill_group(pid)
      raise TimedOut, reason
    end

    def kill_group(pid)
      begin
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
