# frozen_string_literal: true

require_relative '../fact'
require_relative '../game'

module Cdctl
  module Game
    # Two independent witnesses of the game version: the data index and the game's own log. When
    # they disagree the answer is unknown, since an update can land after the last launch.
    module Version
      PAVER = File.join('meta', '0.paver')
      LOG_DIRECTORY = File.join('drive_c', 'users', 'steamuser', 'AppData', 'Local', DATA_DIRECTORY, 'log')
      LOG_PATTERN = /GameVersion: ([0-9.]+)/
      LOG_HEAD = 4096

      module_function

      def read(installation)
        return Fact.unknown('the game installation was not found') unless installation

        from_index = from_paver(File.join(installation.install_path, PAVER))
        from_log = from_log(installation.prefix_path)
        decide(from_index, from_log)
      end

      def decide(from_index, from_log)
        if from_index && from_log && from_index != from_log
          return Fact.unknown("sources disagree: data index says #{from_index}, last launch log says #{from_log}")
        end

        return Fact.known(from_index, source: 'data_index+launch_log') if from_index && from_log
        return Fact.known(from_index, source: 'data_index', confidence: 'inferred') if from_index
        return Fact.known(from_log, source: 'launch_log') if from_log

        Fact.unknown('neither the data index nor a launch log gave a version')
      end

      # The first three little-endian 16-bit values; the game shows them as 2.04.05.
      def from_paver(path)
        major, minor, patch = File.binread(path, 6)&.unpack('v3')
        return nil unless patch

        format('%<major>d.%<minor>02d.%<patch>02d', major:, minor:, patch:)
      rescue SystemCallError
        nil
      end

      def from_log(prefix)
        return nil unless prefix

        directory = File.join(prefix, LOG_DIRECTORY)
        logs = Dir.glob('Launcher_*.log', base: directory).map { File.join(directory, it) }
        newest = logs.max_by { File.mtime(it) } or return nil

        File.binread(newest, LOG_HEAD).to_s[LOG_PATTERN, 1]
      rescue SystemCallError
        nil
      end
    end
  end
end
