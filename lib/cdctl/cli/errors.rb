# frozen_string_literal: true

require_relative '../error'

module Cdctl
  module CLI
    class UsageError < Cdctl::Error
      # A nil hint is filled in by the Runner from the resolved command path.
      attr_reader :hint

      def initialize(message, hint: nil)
        super(message, code: 'USAGE')
        @hint = hint
      end
    end
  end
end
