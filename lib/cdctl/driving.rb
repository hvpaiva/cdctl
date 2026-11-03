# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'capture/frame'
require_relative 'error'
require_relative 'input/keys'
require_relative 'private_files'
require_relative 'recognition/profile'
require_relative 'x11'

module Cdctl
  # Moves the game between screens it recognizes. It never repeats an input for lack of a reaction:
  # this game stalls for seconds on a menu change and presents nothing meanwhile, so an input that
  # looks ignored has usually just not shown yet, and a second one would toggle or skip something.
  # A step sends once and then waits for the screen it expects, or fails.
  module Driving
    # What is on the game window right now.
    class Eyes
      def initialize(connection:, window:, profile:, hud_scale: nil)
        @connection = connection
        @window = window
        @profile = profile
        @recognizer = Recognition::Recognizer.new(profile, hud_scale:)
      end

      def frame
        layout = @connection.pixel_layout(@window.depth, @window.visual)
        unless layout
          raise Error.new("the window uses a pixel format cdctl cannot read (depth #{@window.depth})",
                          code: 'UNSUPPORTED_BACKEND')
        end

        image = @connection.image(@window.id, 0, 0, @window.width, @window.height)
        Capture::Frame.new(width: @window.width, height: @window.height, layout:, pixels: image.data)
      rescue X11::RequestError
        raise Error.new('the game window can no longer be read, so it may have closed',
                        code: 'TARGET_CHANGED', next_steps: ['Run cdctl status.'])
      end

      def look = @recognizer.recognize(frame)

      def sees?(anchor, in_frame = frame) = @profile.anchor_named(anchor).matches?(in_frame)
    end

    # An input that got no answer in time may still be on its way, since the game can stall for longer
    # than any caller wants to wait. Until the screen moves or this much time passes, sending again
    # could undo it, so the next command is told to look first.
    class Unanswered
      FILE = 'unanswered.json'
      HOLD_OFF_SECONDS = 30

      def initialize(directory, clock: -> { Time.now })
        @path = File.join(directory, FILE)
        @directory = directory
        @clock = clock
      end

      def note(screen, expected)
        PrivateFiles.directory(@directory)
        PrivateFiles.write(@path, JSON.generate(screen:, expected:, at: @clock.call.iso8601(3)))
      rescue SystemCallError
        nil
      end

      def clear
        File.unlink(@path)
      rescue SystemCallError
        nil
      end

      def check!(screen)
        record = read
        return unless record
        return clear unless record[:screen] == screen

        left = (HOLD_OFF_SECONDS - (@clock.call - Time.iso8601(record[:at]))).ceil
        return clear unless left.positive?

        steps = ["Look with cdctl observe, and try again in #{left} seconds if the screen has not changed."]
        raise Error.new("the last input from #{screen} got no answer yet and may still be on its way, so nothing was " \
                        'sent', code: 'PRECONDITION_FAILED', details: { retry_after_seconds: left }, next_steps: steps)
      end

      private

      def read
        record = JSON.parse(File.read(@path), symbolize_names: true)
        record.is_a?(Hash) && record[:at].is_a?(String) ? record : nil
      rescue SystemCallError, JSON::ParserError, EncodingError
        nil
      end
    end

    class Navigator
      POLL = 0.1
      # Long enough for the slowest menu change seen, on a game still loading its assets.
      STEP_TIMEOUT = 20.0
      SETTLE_TIMEOUT = 2.0
      # A frame in the middle of a transition can match by chance. Two in a row cannot.
      SAME_LOOKS = 2
      MAX_STEPS = 6
      KEY_HOLD = 0.15
      CLICK_HOLD = 0.08
      POINTER_SETTLE = 0.08
      # A screen draws before it accepts input: a click right after a menu appeared was seen to do
      # nothing on the real game, while the same click a moment later worked.
      ARRIVAL_SETTLE = 0.8
      # After an exit is confirmed these are what success looks like from here.
      GOING_AWAY = %w[TARGET_CHANGED FOCUS_LOST RESOLUTION_CHANGED].freeze

      def initialize(session:, eyes:, profile:, window:, unanswered: nil, step_timeout: STEP_TIMEOUT)
        @session = session
        @eyes = eyes
        @profile = profile
        @window = window
        @unanswered = unanswered
        @step_timeout = step_timeout
        @steps = 0
      end

      def steps_taken = @steps

      # The screen the exit entry is on.
      def quit_entry = @profile.flows.fetch(:quit).fetch(:from)

      # A sequence the profile describes as one thing: one input, an expected screen, and for a
      # confirmation the key that answers it, only once the dialog was recognized.
      def take_flow(name)
        flow = @profile.flows.fetch(name)
        require_entry(flow)
        @steps += 1
        flow[:key] ? send_key(flow[:key], hold: (flow[:hold_ms] || (KEY_HOLD * 1000)) / 1000.0) : click(flow[:click])
        return wait_for([flow[:to]]) if flow[:to]
        return nil unless flow[:dialog]

        wait_for([flow.fetch(:dialog)])
        @session.sender.pause(ARRIVAL_SETTLE)
        @steps += 1
        send_key(flow.fetch(:confirm), hold: flow.fetch(:confirm_hold_ms) / 1000.0)
        nil
      end

      # For a flow that ends the game: its window may go while the key that ends it is still down.
      def take_exit_flow(name)
        take_flow(name)
      rescue Error => e
        raise unless GOING_AWAY.include?(e.code) && !@session.sender.actions.empty?
      end

      # What is on the screen once it holds still, or nil.
      def settled_look
        deadline = now + SETTLE_TIMEOUT
        previous = nil
        same = 0
        loop do
          match = @eyes.look
          same = match&.name == previous&.name ? same + 1 : 1
          previous = match
          return match if same >= SAME_LOOKS
          return nil if now > deadline

          sleep(POLL)
        end
      end

      def go_to(target)
        unless @profile.screen_names.include?(target)
          raise Error.new("this profile does not know #{target}", code: 'UNSUPPORTED_BUILD')
        end

        current = require_screen
        until current.name == target
          take(next_step(current.name, target), current.name, target)
          current = require_screen
        end
        current
      end

      def back
        current = require_screen
        edge = open_edges.find { it[:back] && it[:from].include?(current.name) }
        return current unless edge

        take(edge, current.name, nil)
      end

      # Waits for one of these screens. Losing the focus or seeing other input ends the wait, since
      # nothing looked at after that can be trusted to come from what was sent.
      def wait_for(names, timeout: @step_timeout)
        deadline = now + timeout
        previous = nil
        same = 0
        loop do
          @session.guard.during_hold!
          match = @eyes.look
          same = match && match.name == previous&.name ? same + 1 : 1
          previous = match
          return match if match && names.include?(match.name) && same >= SAME_LOOKS
          raise timed_out(names, match, timeout) if now > deadline

          @session.sender.pause(POLL)
        end
      end

      def send_key(name, hold: KEY_HOLD)
        code = @session.keycode_for(Input::Keys.keysym(name)) or
          raise Error.new("this keyboard layout has no key for #{name}", code: 'PRECONDITION_FAILED')
        @session.sender.press({ kind: 'key', code: }, hold:, description: { type: 'key', key: name, keycode: code })
      end

      # Between two steps of one change: time for the screen to accept input, under the same watch.
      def settle = @session.sender.pause(ARRIVAL_SETTLE)

      def pause_a_moment
        @session.guard.during_hold!
        @session.sender.pause(POLL)
      end

      def click(point)
        x, y = @profile.point(point, @window.height)
        @session.sender.move(@window.x + x, @window.y + y, description: { type: 'move', x:, y:, point: })
        @session.sender.pause(POINTER_SETTLE)
        @session.sender.press({ kind: 'button', code: Input::Keys::BUTTONS.fetch('left') },
                              hold: CLICK_HOLD, description: { type: 'click', x:, y:, button: 'left', point: })
      end

      # Whether one of these is on the screen, waiting for it if it has not drawn yet: a list was
      # measured to draw about a second and a half after its tab. What has only just drawn gets the
      # moment any new screen gets before it takes input.
      def on_screen?(anchors)
        return true if seen?(anchors)
        return false unless appears?(anchors)

        settle
        true
      end

      private

      def seen?(anchors)
        frame = @eyes.frame
        anchors.any? { @eyes.sees?(it, frame) }
      end

      # A longer --timeout is for the long way into the world, and says nothing about a list.
      def appears?(anchors)
        deadline = now + [@step_timeout, STEP_TIMEOUT].min
        same = 0
        loop do
          @session.guard.during_hold!
          same = seen?(anchors) ? same + 1 : 0
          return true if same >= SAME_LOOKS
          return false if now > deadline

          @session.sender.pause(POLL)
        end
      end

      # The entry that a step takes must be on the screen, or the key or the point means something
      # else. A menu with one anchor says which tab is open, and not what a list inside it holds.
      def require_entry(step)
        expected = step[:seen_any]
        return if expected.nil? || on_screen?(expected)

        raise Error.new('the entry this step needs is not on the screen, so its input was not sent',
                        code: 'UNKNOWN_SCREEN', next_steps: ['Read the capture with cdctl observe.'])
      end

      def require_screen
        settled_look or
          raise Error.new('the current screen is not one this profile recognizes, so nothing was sent from here',
                          code: 'UNKNOWN_SCREEN',
                          next_steps: ['Read the capture with cdctl observe. If it is loading, wait and try again.'])
      end

      def take(edge, from, target)
        @steps += 1
        raise Error.new('too many steps without reaching the screen', code: 'VERIFY_FAILED') if @steps > MAX_STEPS

        @unanswered&.check!(from)
        require_entry(edge)
        edge[:key] ? send_key(edge[:key]) : click(edge[:click])
        answered(edge, from).tap { @session.sender.pause(ARRIVAL_SETTLE) if target }
      end

      def answered(edge, from)
        wait_for(edge[:to]).tap { @unanswered&.clear }
      rescue Error => e
        @unanswered&.note(from, edge[:to]) if e.code == 'VERIFY_FAILED'
        raise
      end

      # Some transitions hold only in one context: Escape from the settings returns to wherever they
      # were opened from. What shows on the screen now says which one this is, and a single frame
      # answers for all of them, so the context cannot change halfway through the question.
      def open_edges
        frame = @eyes.frame
        @profile.transitions.select do |edge|
          next false if edge[:requires] && !@eyes.sees?(edge[:requires], frame)

          !(edge[:unless] && @eyes.sees?(edge[:unless], frame))
        end
      end

      def next_step(from, target)
        path = shortest(from, target)
        return path.first if path

        raise Error.new("no known way from #{from} to #{target}",
                        code: 'PRECONDITION_FAILED',
                        next_steps: ['If this is the title screen, enter the game first with cdctl game continue.'])
      end

      def shortest(from, target)
        edges = open_edges
        visited = [from]
        queue = [[from, []]]
        until queue.empty?
          screen, path = queue.shift
          edges.select { it[:from].include?(screen) }.each do |edge|
            return [*path, edge] if edge[:to].include?(target)

            (edge[:to] - visited).each do |name|
              visited << name
              queue << [name, [*path, edge]]
            end
          end
        end
        nil
      end

      def timed_out(names, match, timeout)
        Error.new("waited #{timeout.round} seconds for #{names.join(' or ')} and the screen is " \
                  "#{match&.name || 'not recognized'}", code: 'VERIFY_FAILED',
                                                        next_steps: ['Read the capture with cdctl observe. Do not ' \
                                                                     'repeat the input without looking first: it may ' \
                                                                     'still be on its way.'])
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
