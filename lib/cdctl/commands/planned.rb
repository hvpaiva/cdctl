# frozen_string_literal: true

require_relative '../cli'
require_relative '../error'

module Cdctl
  module Commands
    # A caller reading the requirements may try these. They answer like any other result, with
    # NOT_IMPLEMENTED and exit status 4, instead of looking like a typo.
    module Planned
      NAMES = %w[game hud input menu settings].freeze

      def self.commands
        NAMES.map do |name|
          CLI::Command.new(name:, summary: 'Not implemented yet', hidden: true, raw: true, handler: handler(name))
        end
      end

      def self.handler(name)
        lambda do |_context, _args, _opts|
          raise Error.new("cdctl #{name} is planned but this version does not implement it",
                          code: 'NOT_IMPLEMENTED', next_steps: ['Run cdctl capabilities to see what works today.'])
        end
      end
      private_class_method :handler
    end
  end
end
