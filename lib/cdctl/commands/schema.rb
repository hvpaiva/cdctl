# frozen_string_literal: true

require 'json'
require_relative 'base'
require_relative '../schemas'

module Cdctl
  module Commands
    class Schema < Base
      NAME = 'schema'

      def self.command(factory)
        CLI::Command.new(
          name: NAME, section: 'Discovery Commands', summary: "Print the JSON Schema of a command's result",
          description: "Print the JSON Schema of a command's result, or list the known schemas when no name is " \
                       'given. Each schema is self-contained. A planned command answers NOT_IMPLEMENTED.',
          positionals: [CLI::Positional.new(name: 'NAME', required: false,
                                            description: 'The command, such as status or observation.check.')],
          examples: [CLI::Example.new(comment: 'List the schemas', command: 'schema --json'),
                     CLI::Example.new(comment: 'Print one', command: 'schema status --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, _runtime, args, _opts)
        name = args.first
        return invocation.success(data: { names: Schemas::NAMES, planned: Schemas::PLANNED }) unless name

        invocation.success(data: { name:, schema: Schemas.document(name) })
      end

      def render(context, result)
        return context.puts(JSON.pretty_generate(result.data[:schema])) if result.data[:schema]

        rows(context, [['Available', result.data[:names].join(', ')], ['Planned', result.data[:planned].join(', ')]])
      end
    end
  end
end
