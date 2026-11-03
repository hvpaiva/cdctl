# frozen_string_literal: true

require_relative 'base'
require_relative 'sending'
require_relative '../capabilities'
require_relative '../observer'

module Cdctl
  module Commands
    class Capabilities < Base
      include Sending

      NAME = 'capabilities'

      def self.command(factory)
        CLI::Command.new(
          name: NAME, section: 'Discovery Commands', summary: 'List what works on this machine, and why not',
          description: 'List every capability with its state here: available was proven just now, unverified is ' \
                       'implemented with nothing to try it on, unavailable failed with a reason, observe_only reads ' \
                       'without acting, not_implemented is planned, unsupported does not exist on this platform and ' \
                       "mod_dependent needs a mod.\n\n" \
                       'The JSON form also lists every error code and exit status.',
          examples: [CLI::Example.new(comment: 'Start here', command: 'capabilities --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, _opts)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          profile, reason = profile_for(runtime, snapshot)
          report = Cdctl::Capabilities.new(snapshot:, connection: observer.connection, shell: runtime.shell, profile:,
                                           profile_reason: reason)
          invocation.success(data: report.to_h, target: snapshot.target)
        end
      end

      def render(context, result)
        environment = result.data[:environment]
        context.puts("#{environment[:platform]}, compositor #{environment[:compositor] || 'unknown'}, " \
                     "#{environment[:validation].tr('_', ' ')}", '')
        result.data[:capabilities].each { line(context, it) }
      end

      def line(context, capability)
        context.puts("#{capability[:id].ljust(26)} #{capability[:state].ljust(16)} #{capability[:summary]}")
        context.puts("#{' ' * 43} #{CLI::Style.plain(capability[:reason])}") if capability[:reason]
      end
    end
  end
end
