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
        JSON.parse(File.read(@path), symbolize_names: true).then { it.is_a?(Hash) ? it : { damaged: true } }
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, SystemCallError
        { damaged: true }
      end

      def clear
        File.unlink(@path)
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
