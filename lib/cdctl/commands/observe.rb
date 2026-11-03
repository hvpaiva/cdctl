# frozen_string_literal: true

require_relative 'base'
require_relative 'capturing'
require_relative 'snapshot_view'
require_relative '../fact'
require_relative '../observation_store'

module Cdctl
  module Commands
    class Observe < Base
      include Capturing

      NAME = 'observe'
      NO_RECOGNITION = 'this version has no UI profile, so look at the capture to tell which screen this is'

      def self.command(factory)
        CLI::Command.new(
          name: NAME, section: 'Observation Commands', summary: 'Capture the game and record what was seen',
          description: 'Report the same state as status, capture the game window and store an observation. Its id ' \
                       'names the geometry the capture belongs to: cdctl observation check says whether a ' \
                       "coordinate taken from it still applies.\n\n" \
                       "With a system dialog over the game it stops and answers SYSTEM_DIALOG_PRESENT.\n\n" \
                       'Screen recognition needs a UI profile, so the screen is unknown for now; read the image.',
          examples: [CLI::Example.new(comment: 'Look at the game', command: 'observe --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, _opts)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          artifact = capture(observer, runtime, snapshot, invocation)
          record = ObservationStore.new(runtime.paths.observations_dir)
                                   .save(snapshot.fingerprint, request_id: invocation.request_id, artifact:)
          success(invocation, snapshot.with_capture(artifact), record, artifact)
        end
      end

      def success(invocation, snapshot, record, artifact)
        data = snapshot.to_h.merge(observation_id: record[:id], fingerprint: record[:state],
                                   screen: Fact.unknown(NO_RECOGNITION))
        invocation.success(data:, target: snapshot.target, artifacts: [artifact],
                           not_verified: capture_notes(snapshot, artifact),
                           next_steps: ['Read the PNG in artifacts to see the screen.'])
      end

      def render(context, result)
        rows(context, [['Observation', result.data[:observation_id]], ['Capture', result.artifacts.first[:path]],
                       ['Screen', SnapshotView.fact(result.data[:screen])], *SnapshotView.rows(result.data)])
      end
    end
  end
end
