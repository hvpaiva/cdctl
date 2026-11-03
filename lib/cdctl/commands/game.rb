# frozen_string_literal: true

require_relative 'base'
require_relative 'menu'
require_relative 'sending'
require_relative '../game'
require_relative '../lease'
require_relative '../observer'

module Cdctl
  module Commands
    class GameLaunch < Base
      include Sending

      NAME = 'game launch'
      WAITS = %w[title window none].freeze
      DEFAULT_TIMEOUT = 180
      MAX_TIMEOUT = 900
      POLL = 1.0
      DESCRIPTION = 'Start the game through Steam, which applies the launch options set there. With the game already ' \
                    "open it starts nothing and reports what is there.\n\n" \
                    'It records the display mode at the launch, which is what makes a later change of mode ' \
                    'detectable, and which makes the presentation of the image known.'

      def self.command(factory)
        CLI::Command.new(
          name: 'launch', summary: 'Start the game through Steam and wait for it', description: DESCRIPTION,
          options: [LeaseToken::TOKEN_OPTION,
                    CLI::Option.new(long: 'wait', argument: 'STATE', enum: WAITS, default: 'title',
                                    description: 'What to wait for.'),
                    CLI::Option.new(long: 'timeout', argument: 'SECONDS', default: DEFAULT_TIMEOUT.to_s,
                                    description: "How long to wait, up to #{MAX_TIMEOUT}.")],
          examples: [CLI::Example.new(comment: 'Start and wait for the title screen',
                                      command: 'game launch --wait title --timeout 180 --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, opts)
        limit = whole(opts[:timeout])
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          next already_running(invocation, snapshot) if snapshot.process

          snapshot.installation or raise Error.new('the game is not installed', code: 'GAME_NOT_INSTALLED')
          Lease.for(runtime).verify!(token_from(runtime, opts))
          start(runtime, snapshot)
          await(invocation, runtime, opts[:wait], limit)
        end
      end

      def whole(text)
        value = Integer(text.to_s, 10, exception: false)
        return value if value&.between?(1, MAX_TIMEOUT)

        raise CLI::UsageError, "invalid --timeout #{text.inspect}: expected a whole number from 1 to #{MAX_TIMEOUT}"
      end

      def already_running(invocation, snapshot)
        invocation.success(data: { started: false, window: snapshot.window&.hex_id }.compact, target: snapshot.target,
                           changed: false, after: { process: 'running' },
                           verification: { method: 'process', observed: { pid: snapshot.process.pid } })
      end

      def start(runtime, snapshot)
        output = run_steam(runtime)
        unless output.success?
          raise Error.new("Steam refused the launch: #{output.stderr.strip}", code: 'PRECONDITION_FAILED')
        end

        @display_at_launch = snapshot.resolution[:display_mode]
      end

      def run_steam(runtime)
        runtime.shell.run('steam', '-applaunch', Game::APP_ID.to_s)
      rescue Shell::NotAvailable
        runtime.shell.run('xdg-open', "steam://rungameid/#{Game::APP_ID}")
      rescue Shell::TimedOut
        # A first Steam start stays in the foreground. It started, and the wait below is what proves it.
        Shell::Output.new(stdout: '', stderr: '', exit_status: 0)
      end

      def await(invocation, runtime, wait, limit)
        deadline = now + limit
        loop do
          found = Observer.open(runtime) { look(runtime, it, wait) }
          return done(invocation, found) if found[:done]

          if now > deadline
            raise Error.new("the game did not reach #{wait} in #{limit} seconds", code: 'TIMEOUT', changed: true,
                                                                                  actions: launched,
                                                                                  data: found[:state],
                                                                                  next_steps: ['Run cdctl status.'])
          end
          sleep(POLL)
        end
      end

      def look(runtime, observer, wait)
        snapshot = observer.snapshot
        record_launch(observer, snapshot)
        return { state: { process: false } } unless snapshot.process
        return { done: true, snapshot: } if wait == 'none'
        return { state: { process: true, window: false } } unless snapshot.window
        return { done: true, snapshot: } if wait == 'window'

        match = screen_fact(runtime, observer, snapshot)
        return { done: true, snapshot:, screen: match } if match.known? && match.value[:name] == 'title'

        { state: { process: true, window: true, screen: match.to_h } }
      end

      def record_launch(observer, snapshot)
        observer.note_launch(snapshot.process, @display_at_launch) if snapshot.process && @display_at_launch
      end

      def done(invocation, found)
        snapshot = found[:snapshot]
        screen = found[:screen]&.value
        invocation.success(
          data: { started: true, launch_display_mode: @display_at_launch, window: snapshot.window&.hex_id }.compact,
          target: snapshot.target, changed: true, actions: launched, before: { process: 'closed' },
          after: { process: snapshot.process.pid, screen: screen&.fetch(:name, nil) }.compact,
          verification: { method: screen ? 'visual_anchors' : 'process',
                          observed: { pid: snapshot.process.pid, screen: }.compact }
        )
      end

      def launched = [{ type: 'launch', through: 'steam', app_id: Game::APP_ID }]

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def render(context, result)
        rows(context, [['Started', result.data[:started].to_s], ['Window', result.data[:window].to_s]])
      end
    end

    class GameContinue < DrivingBase
      NAME = 'game continue'
      DEFAULT_TIMEOUT = 180
      DESCRIPTION = 'From the title screen, take the entry that continues the saved game, and wait until the world ' \
                    'is on the screen. It is the same entry as pressing it by hand, so it never starts a new game ' \
                    "and never picks a save.\n\n" \
                    'Already in the world, nothing is sent. Anywhere else it answers PRECONDITION_FAILED.'

      def self.command(factory)
        CLI::Command.new(
          name: 'continue', summary: 'Continue the saved game from the title screen, and wait for the world',
          description: DESCRIPTION,
          options: [LeaseToken::TOKEN_OPTION,
                    CLI::Option.new(long: 'wait', argument: 'SCREEN', enum: %w[world], default: 'world',
                                    description: 'What to wait for.'),
                    CLI::Option.new(long: 'timeout', argument: 'SECONDS', default: DEFAULT_TIMEOUT.to_s,
                                    description: "How long to wait, up to #{MAX_TIMEOUT}."),
                    *COMMON_OPTIONS.drop(2)],
          examples: [CLI::Example.new(comment: 'Enter the game', command: 'game continue --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def drive(navigator, _args)
        before = navigator.settled_look
        return { before:, after: before, expected: 'world' } if before&.name == 'world'

        unless before&.name == 'title'
          raise Error.new("continuing starts from the title screen, and this is #{before&.name || 'not recognized'}",
                          code: 'PRECONDITION_FAILED', next_steps: ['Read the capture with cdctl observe.'])
        end
        { before:, after: navigator.take_flow(:continue), expected: 'world' }
      end
    end

    class GameQuit < DrivingBase
      NAME = 'game quit'
      DEFAULT_TIMEOUT = 60
      DESCRIPTION = 'Reach the exit entry of the game menu, recognize the confirmation dialog, confirm it, and wait ' \
                    "until the process is really gone. A game already closed answers with nothing sent.\n\n" \
                    'It never kills anything: not the game, not Wine and not Steam. If the game does not end, this ' \
                    'answers TIMEOUT and leaves it running.'

      def self.command(factory)
        CLI::Command.new(
          name: 'quit', summary: 'Leave through the game menu and confirm the process ended', description: DESCRIPTION,
          options: [LeaseToken::TOKEN_OPTION,
                    CLI::Option.new(long: 'graceful', description: 'Through the menu, which is the only way this has.'),
                    CLI::Option.new(long: 'wait', argument: 'STATE', enum: %w[closed], default: 'closed',
                                    description: 'What to wait for.'),
                    CLI::Option.new(long: 'timeout', argument: 'SECONDS', default: DEFAULT_TIMEOUT.to_s,
                                    description: "How long to wait for each step, up to #{MAX_TIMEOUT}."),
                    *COMMON_OPTIONS.drop(2)],
          examples: [CLI::Example.new(comment: 'Close the game', command: 'game quit --graceful --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, args, opts)
        scan = Observer.open(runtime, &:snapshot).scan
        return closed_already(invocation) if scan && scan.processes.empty? && !scan.problem

        super
      end

      def closed_already(invocation)
        invocation.success(data: { closed: true, sent: false }, changed: false, after: { process: 'closed' },
                           verification: { method: 'process', observed: { process: 'absent' } })
      end

      def drive(navigator, _args)
        before = navigator.settled_look
        if before&.name == 'title'
          navigator.take_flow(:quit_from_title)
        else
          navigator.go_to(navigator.quit_entry)
          navigator.take_flow(:quit)
        end
        { before: }
      end

      def answer(turn, trip)
        process = turn.snapshot.process
        process_gone!(turn.runtime, process, @timeout)
        turn.invocation.success(
          data: { closed: true, sent: true, activity: turn.session.activity_report, steps: turn.navigator.steps_taken },
          target: turn.snapshot.target, changed: true, actions: turn.session.sender.actions,
          before: { screen: trip[:before]&.name, process: process.pid }, after: { process: 'closed' },
          verification: { method: 'process', observed: { process: 'absent' } }, not_verified: turn.session.not_verified
        )
      end

      def process_gone!(runtime, process, limit)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
        until Lease.start_ticks(runtime.proc_root, process.pid) != process.start_ticks
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise Error.new("the exit was confirmed and the process is still running after #{limit} seconds",
                            code: 'TIMEOUT', next_steps: ['Run cdctl status. Nothing was killed.'])
          end
          sleep(0.25)
        end
      end

      def render(context, result)
        rows(context, [['Closed', result.data[:closed].to_s], ['Steps', result.data[:steps].to_s]])
      end
    end

    module GameCommands
      def self.command(factory)
        CLI::Command.new(name: 'game', section: 'Control Commands', summary: 'Start, enter and leave the game',
                         subcommands: [GameLaunch, GameContinue, GameQuit].map { it.command(factory) })
      end
    end
  end
end
