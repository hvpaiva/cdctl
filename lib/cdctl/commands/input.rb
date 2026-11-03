# frozen_string_literal: true

require_relative 'base'
require_relative 'capturing'
require_relative 'lease'
require_relative '../input/journal'
require_relative '../input/keys'
require_relative '../input/session'
require_relative '../observation_store'
require_relative '../observer'

module Cdctl
  module Commands
    # What every input command shares. The order of perform is the promise: the command line first,
    # then a look at the game, then the lease and the guards, and only then a send. A capture closes
    # it, because a key press proves nothing about what it did.
    class InputBase < Base
      include Capturing
      include LeaseToken

      # One run of a command, so its steps do not each take the same six arguments.
      Turn = Data.define(:invocation, :runtime, :opts, :snapshot, :plan)

      DEFAULT_MAX_AGE = 120
      MAX_SETTLE_MS = 10_000
      CALLER_CHECKS = 'Nothing checked the result of this input. Read the PNG in artifacts.'
      COMMON_OPTIONS = [
        TOKEN_OPTION,
        CLI::Option.new(long: 'settle-ms', argument: 'MS', default: '500',
                        description: "How long to wait before the capture of the result, up to #{MAX_SETTLE_MS}."),
        CLI::Option.new(long: 'no-capture',
                        description: 'Take no capture afterwards. The caller then has no evidence.'),
        CLI::Option.new(long: 'allow-unverified-dialogs',
                        description: 'Send even where a system dialog cannot be ruled out. The result lists ' \
                                     'system_dialogs under not_verified.')
      ].freeze
      OBSERVATION_OPTIONS = [
        CLI::Option.new(long: 'observation', argument: 'ID', required: true,
                        description: 'The observation the coordinates come from. It must still describe the game.'),
        CLI::Option.new(long: 'max-age', argument: 'SECONDS', default: DEFAULT_MAX_AGE.to_s,
                        description: 'Refuse an observation older than this.')
      ].freeze
      COORDINATE_OPTIONS = [
        CLI::Option.new(long: 'x', argument: 'X', required: true, description: 'Pixels from the left of the window.'),
        CLI::Option.new(long: 'y', argument: 'Y', required: true, description: 'Pixels from the top of the window.'),
        CLI::Option.new(long: 'space', argument: 'SPACE', enum: %w[game-client], default: 'game-client',
                        description: 'What the coordinates are relative to.')
      ].freeze

      private

      def perform(invocation, runtime, args, opts)
        plan = plan_from(args, opts)
        bounded(opts[:settle_ms], 'settle-ms', 0, MAX_SETTLE_MS)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          snapshot.require_window!
          check_observation(runtime, snapshot, opts)
          run(observer, Turn.new(invocation:, runtime:, opts:, snapshot:, plan:))
        end
      end

      def run(observer, turn)
        Input::Session.open(**session_options(observer, turn)) do |session|
          act(session, turn.snapshot, turn.plan)
          finish(turn, session)
        rescue Error => e
          raise e.record(actions: session.sender.actions, changed: changed_by(session), target: turn.snapshot.target)
        rescue SignalException => e
          raise Error.new("stopped by #{e.signm}", code: 'INTERRUPTED', actions: session.sender.actions,
                                                   changed: changed_by(session), target: turn.snapshot.target)
        end
      end

      def session_options(observer, turn)
        process = turn.snapshot.process
        { runtime: turn.runtime, connection: observer.connection, snapshot: turn.snapshot,
          token: token_from(turn.runtime, turn.opts), allow_unverified: turn.opts[:allow_unverified_dialogs],
          request_id: turn.invocation.request_id, compositor: observer.compositor_probe(process),
          opener: observer.connection_opener(process) }
      end

      # Nothing sent changed nothing. Once something was sent, only the caller can say what it did.
      def changed_by(session) = session.sender.actions.empty? ? false : nil

      def finish(turn, session)
        sleep(turn.opts[:settle_ms].to_i / 1000.0) unless turn.opts[:no_capture]
        Observer.open(turn.runtime) do |observer|
          after = observer.snapshot
          artifact = evidence(observer, after, turn)
          turn.invocation.success(
            data: { modals: after.modals, activity: session.activity_report, recovered: session.recovered }.compact,
            target: after.target || turn.snapshot.target, changed: nil, actions: session.sender.actions,
            before: turn.snapshot.fingerprint, after: after.fingerprint,
            verification: { method: 'caller_required', screenshot: artifact&.fetch(:path, nil) }.compact,
            artifacts: [artifact].compact, not_verified: notes(after, artifact, session), next_steps: [CALLER_CHECKS]
          )
        end
      end

      # The game may have closed because of this input, which is an answer and not a failure.
      def evidence(observer, after, turn)
        return nil if turn.opts[:no_capture]

        capture(observer, turn.runtime, after, turn.invocation)
      rescue Error
        nil
      end

      def notes(after, artifact, session)
        list = ['input.result']
        list += artifact ? capture_notes(after, artifact) : after.not_verified
        (list + session.not_verified).uniq
      end

      def check_observation(runtime, snapshot, opts)
        return unless opts[:observation]

        saved = ObservationStore.new(runtime.paths.observations_dir).load(opts[:observation])
        age = Time.now - Time.iso8601(saved[:observed_at])
        limit = bounded(opts[:max_age], 'max-age', 0, 86_400)
        if age > limit
          raise Error.new("the observation is #{age.round(1)} seconds old, over the #{limit} allowed",
                          code: 'OBSERVATION_STALE', target: snapshot.target, next_steps: ['Run cdctl observe again.'])
        end
        same_as_observed(saved, snapshot)
      end

      def same_as_observed(saved, snapshot)
        differences = ObservationStore.differences(saved[:state], snapshot.fingerprint)
        return if differences.empty?

        raise Error.new('the game no longer matches this observation', code: ObservationStore.error_code(differences),
                                                                       data: { differences: },
                                                                       target: snapshot.target,
                                                                       next_steps: ['Run cdctl observe again.'])
      end

      def bounded(text, name, minimum, maximum)
        value = Integer(text.to_s, 10, exception: false)
        return value if value&.between?(minimum, maximum)

        raise CLI::UsageError, "invalid --#{name} #{text.inspect}: expected a whole number from #{minimum} to " \
                               "#{maximum}"
      end

      def seconds(text, name, minimum, maximum) = bounded(text, name, minimum, maximum) / 1000.0

      def inside!(snapshot, plan)
        window = snapshot.window
        return if plan[:x] < window.width && plan[:y] < window.height

        raise Error.new("#{plan[:x]},#{plan[:y]} is outside the #{window.width}x#{window.height} window",
                        code: 'PRECONDITION_FAILED', target: snapshot.target)
      end

      def coordinates(opts) = { x: bounded(opts[:x], 'x', 0, 65_535), y: bounded(opts[:y], 'y', 0, 65_535) }

      def move_to_point(session, snapshot, plan)
        inside!(snapshot, plan)
        session.sender.move(snapshot.window.x + plan[:x], snapshot.window.y + plan[:y],
                            description: plan.slice(:x, :y).merge(type: 'move'))
      end

      def render(context, result)
        rows(context, [['Sent', result.actions.map { describe(it) }.join(', ')],
                       ['Capture', result.artifacts.first&.fetch(:path, nil) || 'none taken'],
                       ['Check', result.verification[:method].tr('_', ' ')]])
      end

      def describe(action)
        case action[:type]
        when 'key' then "#{action[:key]} for #{action[:held_ms]} ms"
        when 'click' then "#{action[:button]} click at #{action[:x]},#{action[:y]}"
        when 'move' then "move to #{action[:x]},#{action[:y]}"
        else "wheel #{action[:direction]} at #{action[:x]},#{action[:y]}"
        end
      end
    end

    class InputKey < InputBase
      NAME = 'input key'
      MAX_HOLD_MS = 10_000
      MAX_REPEAT = 20
      MAX_GAP_MS = 2000
      DESCRIPTION = 'Press one key with the game focused, hold it, and release it. Before every press it checks ' \
                    'the lease, the process, the geometry, the focus and system dialogs, and that nothing else is ' \
                    "holding a key.\n\n" \
                    'The release survives an error, a signal and even SIGKILL. Losing the focus or seeing other ' \
                    "input during a hold releases at once and answers FOCUS_LOST or USER_INTERFERENCE.\n\n" \
                    'A key sent proves nothing about what it did, so the answer holds a capture and lists ' \
                    'input.result under not_verified. Read the image.'

      def self.command(factory)
        CLI::Command.new(
          name: 'key', summary: 'Press one key in the game, and always release it', description: DESCRIPTION,
          positionals: [CLI::Positional.new(name: 'KEY',
                                            description: 'An X keysym name: Escape, Return, space, e, F1.')],
          options: options,
          examples: [CLI::Example.new(comment: 'Tap a key', command: 'input key Escape --token TOKEN --json'),
                     CLI::Example.new(comment: 'Hold one', command: 'input key w --hold-ms 800 --token TOKEN --json')],
          handler: new(factory)
        )
      end

      def self.options
        [CLI::Option.new(long: 'hold-ms', argument: 'MS', default: '120',
                         description: "How long to hold it, up to #{MAX_HOLD_MS}."),
         CLI::Option.new(long: 'repeat', argument: 'N', default: '1',
                         description: "How many presses, up to #{MAX_REPEAT}."),
         CLI::Option.new(long: 'gap-ms', argument: 'MS', default: '120',
                         description: "The pause between presses, up to #{MAX_GAP_MS}."),
         CLI::Option.new(long: 'observation', argument: 'ID', description: 'Also require this observation to hold.'),
         CLI::Option.new(long: 'max-age', argument: 'SECONDS', default: DEFAULT_MAX_AGE.to_s,
                         description: 'Refuse an observation older than this.'),
         *COMMON_OPTIONS]
      end
      private_class_method :options

      private

      def plan_from(args, opts)
        { name: args.first, keysym: Input::Keys.keysym(args.first),
          hold: seconds(opts[:hold_ms], 'hold-ms', 1, MAX_HOLD_MS),
          repeat: bounded(opts[:repeat], 'repeat', 1, MAX_REPEAT),
          gap: seconds(opts[:gap_ms], 'gap-ms', 0, MAX_GAP_MS) }
      end

      def act(session, snapshot, plan)
        code = keycode(session, snapshot, plan)
        plan[:repeat].times do |index|
          session.sender.pause(plan[:gap]) unless index.zero?
          session.sender.press({ kind: 'key', code: }, hold: plan[:hold],
                                                       description: { type: 'key', key: plan[:name], keycode: code })
        end
      end

      def keycode(session, snapshot, plan)
        session.keycode_for(plan[:keysym]) or
          raise Error.new("this keyboard layout has no key for #{plan[:name]}", code: 'PRECONDITION_FAILED',
                                                                                target: snapshot.target)
      end
    end

    class InputClick < InputBase
      NAME = 'input click'
      MAX_HOLD_MS = 2000
      SETTLE_POINTER = 0.08
      DESCRIPTION = 'Move the pointer of the X server to a point of the window and click it. The coordinates must ' \
                    'come from an observation that still describes the game, and a point outside the window is ' \
                    "refused. Old coordinates are never converted.\n\n" \
                    'Only the X server sees this. The pointer of the desktop stays where it was.'

      def self.command(factory)
        CLI::Command.new(
          name: 'click', summary: 'Click a point of the game window, from a capture still valid',
          description: DESCRIPTION,
          options: [*COORDINATE_OPTIONS, *OBSERVATION_OPTIONS,
                    CLI::Option.new(long: 'button', argument: 'BUTTON', enum: Input::Keys::BUTTONS.keys,
                                    default: 'left', description: 'Which button.'),
                    CLI::Option.new(long: 'hold-ms', argument: 'MS', default: '80',
                                    description: "How long to hold it, up to #{MAX_HOLD_MS}."),
                    *COMMON_OPTIONS],
          examples: [CLI::Example.new(comment: 'Click from a capture',
                                      command: 'input click --x 540 --y 476 --observation OBS --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def plan_from(_args, opts)
        coordinates(opts).merge(button: opts[:button], hold: seconds(opts[:hold_ms], 'hold-ms', 1, MAX_HOLD_MS))
      end

      def act(session, snapshot, plan)
        move_to_point(session, snapshot, plan)
        session.sender.pause(SETTLE_POINTER)
        session.sender.press({ kind: 'button', code: Input::Keys::BUTTONS.fetch(plan[:button]) },
                             hold: plan[:hold], description: { type: 'click', **plan.slice(:x, :y, :button) })
      end
    end

    class InputMove < InputBase
      NAME = 'input move'

      def self.command(factory)
        CLI::Command.new(
          name: 'move', summary: 'Move the pointer to a point of the game window',
          description: 'Move the pointer of the X server to a point of the window, as for hovering. The coordinates ' \
                       'must come from an observation that still describes the game.',
          options: [*COORDINATE_OPTIONS, *OBSERVATION_OPTIONS, *COMMON_OPTIONS],
          examples: [CLI::Example.new(comment: 'Hover',
                                      command: 'input move --x 540 --y 476 --observation OBS --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def plan_from(_args, opts) = coordinates(opts)

      def act(session, snapshot, plan) = move_to_point(session, snapshot, plan)
    end

    class InputScroll < InputBase
      NAME = 'input scroll'
      MAX_STEPS = 20
      SETTLE_POINTER = 0.08
      STEP_HOLD = 0.03
      STEP_GAP = 0.06

      def self.command(factory)
        CLI::Command.new(
          name: 'scroll', summary: 'Turn the wheel over a point of the game window',
          description: 'Move the pointer of the X server to a point of the window and turn the wheel. The ' \
                       'coordinates must come from an observation that still describes the game.',
          options: [*COORDINATE_OPTIONS, *OBSERVATION_OPTIONS,
                    CLI::Option.new(long: 'direction', argument: 'DIRECTION', enum: Input::Keys::WHEEL.keys,
                                    required: true, description: 'Which way.'),
                    CLI::Option.new(long: 'steps', argument: 'N', default: '1',
                                    description: "How far, up to #{MAX_STEPS}."),
                    *COMMON_OPTIONS],
          examples: [CLI::Example.new(comment: 'Scroll a list',
                                      command: 'input scroll --x 600 --y 500 --direction down --steps 3 ' \
                                               '--observation OBS --token TOKEN')],
          handler: new(factory)
        )
      end

      private

      def plan_from(_args, opts)
        coordinates(opts).merge(direction: opts[:direction], steps: bounded(opts[:steps], 'steps', 1, MAX_STEPS))
      end

      def act(session, snapshot, plan)
        move_to_point(session, snapshot, plan)
        session.sender.pause(SETTLE_POINTER)
        plan[:steps].times do
          session.sender.press({ kind: 'button', code: Input::Keys::WHEEL.fetch(plan[:direction]) },
                               hold: STEP_HOLD, description: { type: 'scroll', **plan.slice(:x, :y, :direction) })
          session.sender.pause(STEP_GAP)
        end
      end
    end

    # Recovery after something killed cdctl and its sentinel together. Every input command does this
    # first, so this is for when no further input is wanted.
    class InputRelease < Base
      include LeaseToken

      NAME = 'input release'

      def self.command(factory)
        CLI::Command.new(
          name: 'release', summary: 'Release what an interrupted command left held',
          description: 'Release the keys and buttons that a killed cdctl recorded as held, and nothing else. It ' \
                       'cannot release what cdctl did not press, so a key a person is holding stays held.',
          options: [TOKEN_OPTION],
          examples: [CLI::Example.new(comment: 'After a crash', command: 'input release --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, opts)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          connection = observer.connection or raise Error.new('X11 is not reachable', code: 'PRECONDITION_FAILED')
          Lease.for(runtime).verify!(token_from(runtime, opts))
          journal = Input::Journal.new(runtime.paths.input_dir)
          answer(invocation, snapshot, Input::Session.settle(journal, connection, runtime.proc_root), connection)
        end
      end

      def answer(invocation, snapshot, recovered, connection)
        released = recovered&.fetch(:released) || 0
        invocation.success(data: { released:, keys_still_held: connection.keys_held.size },
                           target: snapshot.target, changed: !recovered.nil?,
                           actions: recovered ? [{ type: 'release', **recovered }] : [])
      end

      def render(context, result)
        rows(context, [['Released', result.data[:released].to_s],
                       ['Keys still held', result.data[:keys_still_held].to_s]])
      end
    end

    module InputCommands
      def self.command(factory)
        CLI::Command.new(
          name: 'input', section: 'Control Commands',
          summary: 'Send guarded input to the game, with a guaranteed release',
          subcommands: [InputKey, InputClick, InputMove, InputScroll, InputRelease].map { it.command(factory) }
        )
      end
    end
  end
end
