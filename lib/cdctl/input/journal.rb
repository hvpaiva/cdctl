# frozen_string_literal: true

require 'json'
require_relative '../private_files'

module Cdctl
  module Input
    # What is about to be held, on disk before it is pressed. The X server keeps a key down until
    # someone releases it, and a program killed along with its sentinel cannot, so this file is how
    # the next command knows there is something to release.
    class Journal
      FILE = 'held.json'
      KINDS = %w[key button].freeze
      DAMAGED = { damaged: true }.freeze

      def initialize(directory)
        @path = File.join(directory, FILE)
        @directory = directory
      end

      def write(record)
        PrivateFiles.directory(@directory)
        PrivateFiles.write(@path, JSON.generate(record))
      end

      # A file that cannot be read still says a press may have been left behind, so it counts as
      # one with nothing known about it.
      def read
        record = JSON.parse(File.read(@path), symbolize_names: true)
        well_formed?(record) ? record : DAMAGED
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, SystemCallError, EncodingError
        DAMAGED
      end

      def clear
        File.unlink(@path)
      rescue Errno::ENOENT
        nil
      end

      private

      def well_formed?(record)
        return false unless record.is_a?(Hash)

        held = record.fetch(:held, [])
        processes = [record[:owner], record[:sentinel]].compact
        held.is_a?(Array) && held.all? { item?(it) } && processes.all? { process?(it) }
      end

      def item?(item) = item.is_a?(Hash) && KINDS.include?(item[:kind]) && item[:code].is_a?(Integer)

      def process?(process)
        process.is_a?(Hash) && process[:pid].is_a?(Integer) && [Integer, NilClass].include?(process[:start_ticks].class)
      end
    end
  end
end
