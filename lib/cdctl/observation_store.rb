# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require_relative 'error'
require_relative 'private_files'

module Cdctl
  # An observation is the state a caller last saw. A coordinate taken from a capture means nothing
  # once the window moved or the monitor changed mode, so every later action compares against it.
  class ObservationStore
    ID = /\Aobs-[0-9a-f]{16}\z/
    KEEP = 200

    # Which difference means what: a different process is another target, a different size is the
    # same target with coordinates that no longer apply.
    TARGET_FIELDS = %i[boot pid start_ticks window].freeze

    def initialize(directory)
      @directory = directory
    end

    def save(state, request_id:, artifact: nil)
      id = "obs-#{SecureRandom.hex(8)}"
      PrivateFiles.directory(@directory)
      record = { id:, observed_at: Time.now.iso8601(3), request_id:, state:, screenshot: artifact&.fetch(:path, nil) }
      PrivateFiles.write(File.join(@directory, "#{id}.json"), JSON.generate(record))
      PrivateFiles.keep_newest(@directory, 'obs-*.json', KEEP)
      record
    rescue SystemCallError => e
      raise Error.from_system_call(e, @directory)
    end

    def load(id)
      missing(id, 'invalid observation id') unless ID.match?(id)

      record = JSON.parse(File.read(File.join(@directory, "#{id}.json")), symbolize_names: true)
      missing(id, 'unreadable stored observation') unless complete?(record)
      record
    rescue SystemCallError, JSON::ParserError
      missing(id, 'no stored observation named')
    end

    def self.differences(saved, current)
      (saved.keys | current.keys).filter_map do |field|
        next if saved[field] == current[field]

        { field:, was: saved[field], now: current[field] }
      end
    end

    def self.error_code(differences)
      differences.any? { TARGET_FIELDS.include?(it[:field]) } ? 'TARGET_CHANGED' : 'RESOLUTION_CHANGED'
    end

    private

    def complete?(record)
      record.is_a?(Hash) && record[:state].is_a?(Hash) && Time.iso8601(record[:observed_at].to_s)
    rescue ArgumentError
      false
    end

    def missing(id, problem)
      raise Error.new("#{problem} #{id.inspect}", code: 'OBSERVATION_NOT_FOUND',
                                                  next_steps: ['Take a new one with cdctl observe.'])
    end
  end
end
