# frozen_string_literal: true

require_relative 'base'
require_relative 'snapshot_view'
require_relative '../observer'

module Cdctl
  module Commands
    class Status < Base
      NAME = 'status'

      def self.command(factory)
        CLI::Command.new(
          name: NAME, section: 'Observation Commands',
          summary: 'Report the installation, process, window and resolution',
          description: 'Report what can be proven now about the installation, the game process, its window, the ' \
                       "compositor and the resolution, each with its source. It sends nothing to the game.\n\n" \
                       'A closed game is a normal answer with exit status 0.',
          examples: [CLI::Example.new(comment: 'Read the state as JSON', command: 'status --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, _opts)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          snapshot.require_no_timeout!
          invocation.success(data: snapshot.to_h, target: snapshot.target, not_verified: snapshot.not_verified)
        end
      end

      def render(context, result)
        rows(context, SnapshotView.rows(result.data))
      end
    end
  end
end
