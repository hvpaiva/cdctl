# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require_relative 'error'

module Cdctl
  # The contract every command answers with. Keys stay in this order so a human reading raw JSON
  # sees the outcome first.
  Result = Data.define(:request_id, :command, :ok, :status, :started_at, :duration_ms, :target, :data, :artifacts,
                       :not_verified, :error, :next_steps, :exit_status) do
    def to_h
      {
        schema_version: Result::SCHEMA_VERSION, request_id:, command:, ok:, status:, started_at:, duration_ms:,
        changed: false, actions: [], target:, data:, artifacts:, not_verified:, error:, next_steps:
      }
    end

    def to_json_document(pretty:)
      plain = Result.plain(to_h)
      pretty ? JSON.pretty_generate(plain) : JSON.generate(plain)
    end

    # A window title or path can hold invalid UTF-8, which JSON refuses to encode.
    def self.plain(value)
      case value
      when Hash then value.to_h { |key, item| [key, plain(item)] }
      when Array then value.map { plain(it) }
      when String then String.new(value, encoding: Encoding::UTF_8).scrub
      when Symbol then value.to_s
      when Numeric, true, false, nil then value
      else plain(value.to_h)
      end
    end
  end
  Result::SCHEMA_VERSION = '1'

  # Measures one command and builds its Result. Time comes from one wall clock reading and the
  # monotonic clock, so a clock change during a command cannot produce a negative duration.
  class Invocation
    REQUEST_ID = /\A[A-Za-z0-9._:-]{1,64}\z/

    attr_reader :command, :request_id

    def self.request_id(given)
      return SecureRandom.hex(8) if given.nil?
      return given if REQUEST_ID.match?(given)

      raise Error.new("invalid request id #{given.inspect}: use 1 to 64 letters, digits, dots, colons, " \
                      'dashes or underscores', code: 'USAGE')
    end

    def initialize(command:, request_id:)
      @command = command
      @request_id = request_id
      @started_at = Time.now
      @started = monotonic
    end

    def success(data:, target: nil, artifacts: [], not_verified: [], next_steps: [])
      build(ok: true, status: 'ok', data:, target:, artifacts:, not_verified:, error: nil, next_steps:, exit_status: 0)
    end

    def failure(error, not_verified: [])
      build(ok: false, status: error.result_status, data: error.data, target: error.target, artifacts: [],
            not_verified:, error: error_body(error), next_steps: error.next_steps, exit_status: error.exit_status)
    end

    private

    def build(**fields)
      Result.new(request_id:, command:, started_at: @started_at.iso8601(3), duration_ms: elapsed, **fields)
    end

    def error_body(error)
      { code: error.code, message: error.message, details: error.details }.compact
    end

    def elapsed = ((monotonic - @started) * 1000).round

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
