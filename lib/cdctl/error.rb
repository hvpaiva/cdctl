# frozen_string_literal: true

require_relative 'error_codes'

module Cdctl
  # Every failure a caller can act on. `data` and `target` carry what was observed before the
  # failure, so a caller does not have to ask again.
  class Error < StandardError
    # Ruby appends ` @ rb_sysopen - /path` to a SystemCallError; the reader needs the path and
    # the strerror text alone.
    SYSTEM_SUFFIX = / @ \S+ - .*\z/m

    attr_reader :code, :next_steps, :data, :target, :details, :actions, :changed, :artifacts, :not_verified

    def self.from_system_call(error, path, code: 'PRECONDITION_FAILED')
      new("#{path}: #{error.message.sub(SYSTEM_SUFFIX, '')}", code:)
    end

    # `actions` and `changed` report what already happened: a failure after a key press still pressed it.
    def initialize(message = nil, code: 'INTERNAL_ERROR', next_steps: [], data: nil, target: nil, details: nil,
                   actions: [], changed: false, artifacts: [], not_verified: [])
      super(message)
      @code = code
      @next_steps = next_steps
      @data = data
      @target = target
      @details = details
      @actions = actions
      @changed = changed
      @artifacts = artifacts
      @not_verified = not_verified
    end

    def category = ErrorCodes.category(code)

    def exit_status = category.exit_status

    def result_status = category.result_status

    # Usage errors point at a help page; every other error prints its message alone.
    def hint = nil
  end
end
