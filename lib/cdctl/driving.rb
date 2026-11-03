# frozen_string_literal: true

require_relative 'capture/frame'
require_relative 'error'
require_relative 'input/keys'
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
      end

      def look = @recognizer.recognize(frame)

      def sees?(anchor) = @profile.anchor_named(anchor).matches?(frame)
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

      attr_reader :actions

      def initialize(session:, eyes:, profile:, window:, step_timeout: STEP_TIMEOUT)
        @session = session
        @eyes = eyes
        @profile = profile
        @window = window
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
          take(next_step(current.name, target), target)
          current = require_screen
        end
        current
      end

      def back
        current = require_screen
        edge = open_edges.find { it[:back] && it[:from].include?(current.name) }
        return current unless edge

        take(edge, nil)
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
          raise timed_out(names, match) if now > deadline

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

      private

      # The entry that a flow takes must be on the screen, or the key means something else.
      def require_entry(flow)
        expected = flow[:seen_any]
        return if expected.nil? || expected.any? { @eyes.sees?(it) }

        raise Error.new('the entry this expects is not on the screen, so nothing was sent',
                        code: 'UNKNOWN_SCREEN', next_steps: ['Read the capture with cdctl observe.'])
      end

      def require_screen
        settled_look or
          raise Error.new('the current screen is not one this profile recognizes, so nothing was sent from here',
                          code: 'UNKNOWN_SCREEN',
                          next_steps: ['Read the capture with cdctl observe. If it is loading, wait and try again.'])
      end

      def take(edge, target)
        @steps += 1
        raise Error.new('too many steps without reaching the screen', code: 'VERIFY_FAILED') if @steps > MAX_STEPS

        edge[:key] ? send_key(edge[:key]) : click(edge[:click])
        wait_for(edge[:to]).tap { @session.sender.pause(ARRIVAL_SETTLE) if target }
      end

      # Some transitions hold only in one context: Escape from the settings returns to wherever they
      # were opened from. What shows on the screen now says which one this is.
      def open_edges
        @profile.transitions.select do |edge|
          next false if edge[:requires] && !@eyes.sees?(edge[:requires])

          !(edge[:unless] && @eyes.sees?(edge[:unless]))
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

      def timed_out(names, match)
        Error.new("waited #{@step_timeout.round} seconds for #{names.join(' or ')} and the screen is " \
                  "#{match&.name || 'not recognized'}", code: 'VERIFY_FAILED',
                                                        next_steps: ['Read the capture with cdctl observe. Do not ' \
                                                                     'repeat the input without looking first.'])
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
