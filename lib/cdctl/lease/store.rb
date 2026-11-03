# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../error'
require_relative '../private_files'

module Cdctl
  class Lease
    # The one record and its history on disk. Each change happens under flock, which ends with its
    # process, and lands with an atomic rename, so a crash leaves the previous state whole.
    class Store
      class Damaged < StandardError; end

      FILE = 'lease.json'
      LOCK_FILE = 'lease.lock'
      HISTORY_FILE = 'lease-history.jsonl'
      HISTORY_KEEP = 200
      LOCK_TIMEOUT = 2.0
      LOCK_POLL = 0.01

      def initialize(directory)
        @directory = directory
      end

      def locked
        PrivateFiles.directory(@directory)
        File.open(File.join(@directory, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
          wait_for(lock)
          yield
        end
      rescue SystemCallError => e
        raise Error.from_system_call(e, @directory)
      end

      # Reading needs no lock: a rename replaces the file whole.
      def read
        record = JSON.parse(File.read(path), symbolize_names: true)
        raise Damaged, 'it does not hold a lease' unless complete?(record)

        record
      rescue Errno::ENOENT
        { generation: 0, state: 'free' }
      rescue JSON::ParserError, SystemCallError, ArgumentError, EncodingError => e
        raise Damaged, e.message.scrub.lines.first.to_s.strip
      end

      def replace(record)
        PrivateFiles.write(path, JSON.generate(record))
        record
      end

      # The history explains what happened afterwards, so failing to write it never blocks a lease.
      def log(line)
        history = File.join(@directory, HISTORY_FILE)
        File.open(history, File::WRONLY | File::APPEND | File::CREAT, 0o600) { it.puts(JSON.generate(line)) }
        lines = File.readlines(history)
        PrivateFiles.write(history, lines.last(HISTORY_KEEP).join) if lines.size > HISTORY_KEEP * 2
      rescue SystemCallError
        nil
      end

      # The highest generation the history mentions, for going on after the record itself was lost.
      def last_generation
        File.readlines(File.join(@directory, HISTORY_FILE)).filter_map do |line|
          JSON.parse(line.scrub)['generation']
        rescue JSON::ParserError
          nil
        end.grep(Integer).max.to_i
      rescue SystemCallError
        0
      end

      private

      def path = File.join(@directory, FILE)

      def wait_for(lock)
        deadline = monotonic + LOCK_TIMEOUT
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Error.new('the lease is busy being changed', code: 'TIMEOUT') if monotonic > deadline

          sleep(LOCK_POLL)
        end
      end

      def complete?(record)
        return false unless record.is_a?(Hash) && record[:generation].is_a?(Integer)
        return record[:state] == 'free' unless record[:state] == 'held'

        Time.iso8601(record[:renewed_at].to_s) && record[:token_sha256].is_a?(String) && record[:owner].is_a?(String) &&
          holder?(record[:holder])
      end

      def holder?(holder)
        holder.nil? || (holder.is_a?(Hash) && holder[:pid].is_a?(Integer) && holder[:start_ticks].is_a?(Integer))
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
