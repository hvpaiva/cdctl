# frozen_string_literal: true

require_relative 'base'
require_relative 'sending'
require_relative '../observer'

module Cdctl
  module Commands
    # What navigation shares: where the game was, where it is now, and the proof.
    class DrivingBase < Base
      include Sending

      # One run of a command, so its steps do not each take the same arguments.
      Turn = Data.define(:invocation, :runtime, :snapshot, :session, :navigator)

      COMMON_OPTIONS = [
        LeaseToken::TOKEN_OPTION,
        CLI::Option.new(long: 'timeout', argument: 'SECONDS', default: '20',
                        description: 'How long to wait for each screen, up to 300. Nothing is sent again meanwhile.'),
        CLI::Option.new(long: 'allow-unverified-dialogs',
                        description: 'Send even where a system dialog cannot be ruled out. The result lists ' \
                                     'system_dialogs under not_verified.')
      ].freeze
      MAX_TIMEOUT = 300

      private

      def perform(invocation, runtime, args, opts)
        @timeout = bounded_timeout(opts[:timeout])
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          snapshot.require_window!
          driving(invocation, runtime, observer, snapshot, opts) { |turn| answer(turn, drive(turn.navigator, args)) }
        end
      end

      def driving(invocation, runtime, observer, snapshot, opts)
        profile = require_profile(runtime, snapshot)
        require_preset(profile, snapshot)
        with_session(observer, runtime, invocation, snapshot, opts) do |session|
          navigator = Driving::Navigator.new(session:, eyes: eyes_for(observer, snapshot, profile), profile:,
                                             unanswered: Driving::Unanswered.new(runtime.paths.input_dir),
                                             window: snapshot.window, step_timeout: @timeout.to_f)
          yield Turn.new(invocation:, runtime:, snapshot:, session:, navigator:)
        end
      end

      def bounded_timeout(text)
        value = Integer(text.to_s, 10, exception: false)
        return value if value&.between?(1, MAX_TIMEOUT)

        raise CLI::UsageError, "invalid --timeout #{text.inspect}: expected a whole number from 1 to #{MAX_TIMEOUT}"
      end

      def answer(turn, trip)
        Observer.open(turn.runtime) do |later|
          fresh = later.snapshot
          artifact = capture_if_possible(later, turn.runtime, fresh, turn.invocation)
          verification = { method: 'visual_anchors', screenshot: artifact&.fetch(:path, nil), expected: trip[:expected],
                           observed: trip[:after].to_h }.compact
          screens = { before: { screen: trip[:before]&.name },
                      after: { screen: trip[:after].name, score: trip[:after].score.round(3) } }
          turn.invocation.success(**sent_so_far(turn, fresh, artifact), **screens, verification:,
                                                                                   artifacts: [artifact].compact)
        end
      end

      # A release left over from an earlier command counts as a change too: it is a key let go.
      def sent_so_far(turn, fresh, artifact)
        actions = turn.session.sender.actions
        { data: { modals: fresh.modals, activity: turn.session.activity_report, steps: turn.navigator.steps_taken },
          target: fresh.target || turn.snapshot.target, actions:, changed: !actions.empty?,
          not_verified: (with_the_screen_known(notes_on(fresh, artifact)) + turn.session.not_verified).uniq }
      end

      def render(context, result)
        rows(context, [['Before', result.before[:screen].to_s], ['After', result.after[:screen]],
                       ['Steps', result.data[:steps].to_s],
                       ['Capture', result.artifacts.first&.fetch(:path, nil) || 'none taken']])
      end
    end

    class MenuOpen < DrivingBase
      NAME = 'menu open'
      TARGETS = {
        'map' => 'menu.map', 'inventory' => 'menu.inventory', 'journal' => 'menu.journal', 'skills' => 'menu.skills',
        'others' => 'menu.others', 'settings.video' => 'settings.video', 'settings.graphics' => 'settings.graphics',
        'settings.language' => 'settings.language', 'settings.input' => 'settings.input',
        'settings.gameplay' => 'settings.gameplay', 'settings.accessibility' => 'settings.accessibility'
      }.freeze

      def self.command(factory)
        CLI::Command.new(
          name: 'open', summary: 'Reach a menu and prove it is open',
          description: 'Recognize the current screen, walk the transitions known for this build, and verify the ' \
                       "destination. A menu already open stays open and nothing is sent.\n\n" \
                       'Each step sends once and then waits for the screen it expects, however long the game takes, ' \
                       'up to --timeout. A screen it does not recognize answers UNKNOWN_SCREEN and sends nothing.',
          positionals: [CLI::Positional.new(name: 'MENU', enum: TARGETS.keys, description: 'Which menu.')],
          options: COMMON_OPTIONS,
          examples: [CLI::Example.new(comment: 'Open the map', command: 'menu open map --token TOKEN --json'),
                     CLI::Example.new(comment: 'Open the input settings',
                                      command: 'menu open settings.input --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def drive(navigator, args)
        expected = TARGETS.fetch(args.first)
        before = navigator.settled_look
        { before:, after: navigator.go_to(expected), expected: }
      end
    end

    class MenuBack < DrivingBase
      NAME = 'menu back'

      def self.command(factory)
        CLI::Command.new(
          name: 'back', summary: 'Go back one menu level, where that is known',
          description: 'Leave the current menu by the way known for it, and verify the result. In the world, or on ' \
                       'the title screen, there is nothing to go back from and nothing is sent. Escape means ' \
                       'different things on different screens, so an unrecognized screen answers UNKNOWN_SCREEN.',
          options: COMMON_OPTIONS,
          examples: [CLI::Example.new(comment: 'Close a menu', command: 'menu back --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def drive(navigator, _args)
        before = navigator.settled_look
        after = navigator.back
        { before:, after:, expected: after.name }
      end
    end

    module MenuCommands
      def self.command(factory)
        CLI::Command.new(name: 'menu', section: 'Control Commands', summary: 'Reach menus by what they are',
                         subcommands: [MenuOpen, MenuBack].map { it.command(factory) })
      end
    end
  end
end
