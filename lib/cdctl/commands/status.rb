# frozen_string_literal: true

require_relative 'base'
require_relative 'snapshot_view'
require_relative '../input/journal'
require_relative '../input/session'
require_relative '../lease'
require_relative '../observer'

module Cdctl
  module Commands
    class Status < Base
      NAME = 'status'
      LEFT_HELD = 'A killed cdctl left input held. Run cdctl input release, or send any input, to release it.'

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
          input = Input::Session.journal_state(Input::Journal.new(runtime.paths.input_dir), runtime.proc_root)
          invocation.success(data: snapshot.to_h.merge(lease: Lease.for(runtime).status, input:),
                             target: snapshot.target, not_verified: snapshot.not_verified,
                             next_steps: input[:state] == 'left_held' ? [LEFT_HELD] : [])
        end
      end

      def render(context, result)
        rows(context, [*SnapshotView.rows(result.data), ['Input lease', SnapshotView.lease(result.data[:lease])],
                       ['Input left held', result.data[:input][:state] == 'left_held' ? 'yes' : 'no']])
      end
    end
  end
end
