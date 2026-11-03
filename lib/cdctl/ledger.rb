# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'private_files'

module Cdctl
  # Remembers the first time each game process was seen, with no service running: cdctl cannot know
  # the display mode at a launch it did not perform, but it can tell when the mode changed after
  # the first look, which is the change known to crop or stretch the game.
  class Ledger
    KEEP = 32

    Record = Data.define(:first_seen_at, :window_size, :display_size, :fresh) do
      def fresh? = fresh

      def first_seen = { at: first_seen_at, window: window_size, display: display_size }.compact

      # A mode read from the compositor and one read from X11 can differ with nothing having changed.
      def comparable?(display) = !display_size.nil? && !display.nil? && display_size[:source] == display[:source]

      def differences(window:, display:)
        { window: [window_size, window], display: [display_size, display] }.filter_map do |field, (was, now)|
          { field:, was:, now: } unless was == now
        end
      end
    end

    def initialize(directory)
      @directory = directory
    end

    def record(identity, window:, display:)
      read(identity) || store(identity, window:, display:)
    end

    private

    def path(identity) = File.join(@directory, "#{identity}.json")

    def read(identity)
      data = JSON.parse(File.read(path(identity)), symbolize_names: true)
      return nil unless data.is_a?(Hash) && data[:first_seen_at]

      Record.new(first_seen_at: data[:first_seen_at], window_size: data[:window], display_size: data[:display],
                 fresh: false)
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def store(identity, window:, display:)
      at = Time.now.iso8601(3)
      PrivateFiles.directory(@directory)
      PrivateFiles.write(path(identity), JSON.generate(first_seen_at: at, window:, display:))
      PrivateFiles.keep_newest(@directory, '*.json', KEEP)
      Record.new(first_seen_at: at, window_size: window, display_size: display, fresh: true)
    rescue SystemCallError
      nil
    end
  end
end
