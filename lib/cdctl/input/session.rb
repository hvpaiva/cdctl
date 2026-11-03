# frozen_string_literal: true

require 'time'
require_relative '../error'
require_relative '../lease'
require_relative '../private_files'
require_relative '../x11'
require_relative 'activity'
require_relative 'guard'
require_relative 'journal'
require_relative 'sender'
require_relative 'sentinel'

module Cdctl
  module Input
    # Everything one input command needs while it acts, opened together and closed together. It
    # starts by settling what an earlier command may have left held, so nothing is sent on top of it.
    class Session
      NOT_WATCHED_ENTRY = 'input.no_other_source'
      LEFTOVER_WAIT = 1.5
      LOCK_FILE = 'session.lock'

      attr_reader :sender, :guard, :recovered

      def self.open(**)
        session = new(**)
        session.start
        yield session
      ensure
        session&.close
      end

      def initialize(runtime:, connection:, opener:, snapshot:, token:, allow_unverified:, compositor:, request_id:)
        @runtime = runtime
        @connection = connection
        @opener = opener
        @snapshot = snapshot
        @token = token
        @allow_unverified = allow_unverified
        @compositor = compositor
        @request_id = request_id
        @lease = Lease.for(runtime)
        @journal = Journal.new(runtime.paths.input_dir)
      end

      def start
        require_xtest
        @lease.verify!(@token)
        take_turn
        @lease.touch(@token, request_id: @request_id)
        @recovered = Session.settle(@journal, @connection, @runtime.proc_root)
        @guard = build_guard
        @activity = Activity.open(@opener)
        start_sentinel
        @sender = Sender.new(connection: @connection, guard: @guard, activity: @activity, journal: @journal,
                             sentinel: @sentinel, journal_base: journal_base, actions: recovered_actions)
      end

      # A journal still there means something may still be held, whatever stopped this on the way
      # out, so the sentinel is left to release it. "Done" would dismiss it with the key down.
      def close
        if @sentinel
          @journal.read ? @sentinel.abandon : @sentinel.finish
        end
        @activity&.close
        @turn&.close
      end

      def keycode_for(keysym) = @connection.keycode_for(keysym)

      def not_verified
        list = @guard.not_verified
        list += [NOT_WATCHED_ENTRY] unless @activity.watching?
        list
      end

      def activity_report
        return { watched: false, reason: @activity.not_watched_reason } unless @activity.watching?

        { watched: true, other_sources: @activity.counts }
      end

      # What the last command left behind, if it could not clean up. A live owner is still working,
      # and a live sentinel is about to release, so only a journal with neither is a leftover. A
      # press on another X server cannot be released from here, so the journal stays for whoever can.
      def self.settle(journal, connection, proc_root)
        record = wait_for_owners(journal, proc_root)
        return nil unless record

        other_display!(record, connection)
        held = Array(record[:held])
        held.reverse_each { release(connection, it) }
        journal.clear
        { released: held.size, pressed_at: record[:pressed_at], request_id: record[:request_id],
          unreadable: record[:damaged] }.compact
      end

      def self.other_display!(record, connection)
        return if record[:display].nil? || record[:display] == connection.display

        raise Error.new("a press was left on display #{record[:display]}, and this is connected to " \
                        "#{connection.display}", code: 'PRECONDITION_FAILED',
                                                 next_steps: ['Run this where that display can be reached.'])
      end
      private_class_method :other_display!

      def self.wait_for_owners(journal, proc_root)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LEFTOVER_WAIT
        loop do
          record = journal.read
          return record unless record && owner_alive?(record, proc_root)

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise Error.new('another cdctl process is sending input', code: 'PRECONDITION_FAILED',
                                                                      next_steps: ['Wait for it to finish.'])
          end
          sleep(0.02)
        end
      end
      private_class_method :wait_for_owners

      def self.owner_alive?(record, proc_root)
        [record[:owner], record[:sentinel]].compact.any? do |process|
          process[:start_ticks] && Lease.start_ticks(proc_root, process[:pid]) == process[:start_ticks]
        end
      end
      private_class_method :owner_alive?

      # For a command that only reports: whether something was left held, without touching it.
      def self.journal_state(journal, proc_root)
        record = journal.read
        return { state: 'clear' } unless record
        return { state: 'in_progress', request_id: record[:request_id] }.compact if owner_alive?(record, proc_root)

        { state: 'left_held', pressed_at: record[:pressed_at], request_id: record[:request_id],
          count: Array(record[:held]).size }.compact
      end

      def self.release(connection, item)
        if item[:kind] == 'key'
          connection.fake_key(item[:code], down: false)
        else
          connection.fake_button(item[:code], down: false)
        end
      end
      private_class_method :release

      private

      def require_xtest
        return if @connection.xtest?

        raise Error.new('this X server has no XTEST extension, which is how input is sent',
                        code: 'UNSUPPORTED_BACKEND')
      end

      # The journal describes one hold, so one command acts at a time, even under one token. The lock
      # ends with its process, and the sentinel keeps it until its own work is over.
      def take_turn
        directory = @runtime.paths.input_dir
        PrivateFiles.directory(directory)
        @turn = File.open(File.join(directory, LOCK_FILE), File::RDWR | File::CREAT, 0o600)
        return if @turn.flock(File::LOCK_EX | File::LOCK_NB)

        raise Error.new('another cdctl process is sending input', code: 'PRECONDITION_FAILED',
                                                                  next_steps: ['Wait for it to finish.'])
      rescue SystemCallError => e
        raise Error.from_system_call(e, directory)
      end

      def recovered_actions
        return [] unless @recovered && @recovered[:released].positive?

        [{ type: 'release', **@recovered }]
      end

      def build_guard
        Guard.new(connection: @connection, process: @snapshot.process, window: @snapshot.window, lease: @lease,
                  token: @token, proc_root: @runtime.proc_root, compositor: @compositor,
                  ignored: @runtime.settings.ignored_overlay_layers, allow_unverified: @allow_unverified)
      end

      def start_sentinel
        @sentinel = Sentinel.start(open_connection: @opener, journal: @journal, inherited: [@connection, @activity])
      rescue Sentinel::Unavailable, X11::Error => e
        raise Error.new("nothing was sent, because the release could not be guaranteed: #{e.message}",
                        code: 'PRECONDITION_FAILED')
      end

      def journal_base
        { display: @connection.display, request_id: @request_id, owner: process_entry(Process.pid),
          sentinel: process_entry(@sentinel.pid) }
      end

      def process_entry(pid) = { pid:, start_ticks: Lease.start_ticks(@runtime.proc_root, pid) }
    end
  end
end
