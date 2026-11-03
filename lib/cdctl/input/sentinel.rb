# frozen_string_literal: true

require 'json'

module Cdctl
  module Input
    # The other half of "a key is never left down". The X server keeps a key pressed until someone
    # releases it, and a process killed with SIGKILL runs no ensure block. So a second process, in
    # its own session and deaf to ordinary signals, watches a pipe from the first: when the pipe
    # closes without a "done", or a hold outlives its deadline, it releases what it was told is held.
    # Its death closes the other pipe, and the first process then releases by itself. Only a kill of
    # both at once gets past this, which is what the journal is for.
    class Sentinel
      class Unavailable < StandardError; end

      READY_TIMEOUT = 1.0
      # A hold ends on time unless something is wrong, so this only has to outlast a slow check.
      MARGIN = 1.0
      EXIT_TIMEOUT = 2.0
      DEAF_TO = %w[INT TERM HUP QUIT PIPE USR1 USR2 ALRM].freeze
      STANDARD_STREAMS = [0, 1, 2].freeze
      DONE = 'done'
      READY = 'ready'
      ARMED = 'armed'
      EXPIRED = 'expired'

      attr_reader :pid

      def self.start(open_connection:, journal:, inherited: [])
        to_read, to_write = IO.pipe
        from_read, from_write = IO.pipe
        pid = Process.fork do
          to_write.close
          from_read.close
          inherited.each { close_quietly(it) }
          run_child(to_read, from_write, open_connection, journal)
        end
        to_read.close
        from_write.close
        new(pid, to_write, from_read).tap(&:wait_until_ready)
      end

      def self.close_quietly(resource)
        resource.close
      rescue IOError, SystemCallError
        nil
      end
      private_class_method :close_quietly

      # exit! because at_exit handlers and open ensure blocks belong to the parent.
      def self.run_child(read, write, open_connection, journal)
        Process.setsid
        DEAF_TO.each { Signal.trap(it, 'IGNORE') }
        detach_from_caller
        Watch.new(read, write, open_connection.call, journal).run
        Process.exit!(0)
      rescue StandardError
        Process.exit!(1)
      end
      private_class_method :run_child

      # A caller reading this program's output waits until every holder of the pipe closes it, and
      # this process can outlive the program. Reopening on a path instead of on an IO crashes Ruby 4.0
      # when the descriptor was inherited, so it stays this way.
      def self.detach_from_caller
        File.open(File::NULL, File::RDWR) do |null|
          STANDARD_STREAMS.each { IO.for_fd(it, autoclose: false).reopen(null) }
        end
      end
      private_class_method :detach_from_caller

      def initialize(pid, write, read)
        @pid = pid
        @write = write
        @read = read
        @gone = false
        @expired = false
      end

      def wait_until_ready
        return if answered?(READY)

        close_and_reap
        raise Unavailable, 'the process that guarantees the release did not start'
      end

      # Waits for the answer, because a press must not happen before the release is covered.
      def arm(items, seconds)
        @expired = false
        send_line(JSON.generate(held: items, seconds: seconds + MARGIN))
        answered?(ARMED) or raise Unavailable, 'the process that guarantees the release did not answer'
      end

      # A sentinel that fails to answer here has nothing to release anyway.
      def disarm
        send_line(JSON.generate(held: [], seconds: nil))
        answered?(ARMED)
        nil
      end

      # What went wrong on its side, if anything: :expired or :gone.
      def trouble
        take_pending
        return :gone if @gone

        @expired ? :expired : nil
      end

      # Whether it already released what was armed, because a hold outlived its deadline.
      def expired?
        take_pending
        @expired
      end

      def finish
        send_line(DONE)
      rescue Unavailable
        nil
      ensure
        close_and_reap
      end

      # Closing without "done" is the same signal a dead owner gives, so the sentinel releases.
      def abandon = close_and_reap

      private

      def send_line(text)
        @write.puts(text)
        @write.flush
      rescue IOError, SystemCallError
        @gone = true
        raise Unavailable, 'the process that guarantees the release is gone'
      end

      # An expiry can be on its way at any moment, so it is taken note of and the answer is still
      # waited for. Taking it as the answer would leave the real one for the next question.
      def answered?(expected)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
        loop do
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false unless left.positive? && @read.wait_readable(left)

          line = read_line
          return true if line == expected
          return false unless line == EXPIRED

          @expired = true
        end
      end

      def take_pending
        while !@gone && @read.wait_readable(0)
          line = read_line
          @gone = line.nil?
          @expired ||= line == EXPIRED
        end
      rescue IOError
        @gone = true
      end

      def read_line
        @read.gets&.chomp
      rescue IOError, SystemCallError
        nil
      end

      def close_and_reap
        [@write, @read].each { self.class.send(:close_quietly, it) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + EXIT_TIMEOUT
        until Process.wait(@pid, Process::WNOHANG)
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep(0.002)
        end
      rescue Errno::ECHILD
        nil
      end

      # The child's side: it only ever knows what the parent last told it.
      class Watch
        def initialize(read, write, connection, journal)
          @read = read
          @write = write
          @connection = connection
          @journal = journal
          @held = []
          @deadline = nil
        end

        def run
          say(READY)
          loop do
            if @read.wait_readable(seconds_left)
              return unless keep_watching?(@read.gets&.chomp)
            else
              expire
            end
          end
        end

        private

        def seconds_left
          @deadline && [@deadline - now, 0].max
        end

        def keep_watching?(line)
          return false if line == DONE

          if line.nil?
            release_all
            return false
          end

          message = JSON.parse(line, symbolize_names: true)
          @held = message[:held]
          @deadline = message[:seconds] && (now + message[:seconds])
          say(ARMED)
          true
        end

        def expire
          release_all
          @deadline = nil
          say(EXPIRED)
        end

        def release_all
          @held.reverse_each { release(it) }
          @held = []
          @journal.clear
        end

        def release(item)
          if item[:kind] == 'key'
            @connection.fake_key(item[:code], down: false)
          else
            @connection.fake_button(item[:code], down: false)
          end
        end

        def say(text)
          @write.puts(text)
          @write.flush
        rescue IOError, SystemCallError
          nil
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
