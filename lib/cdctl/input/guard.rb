# frozen_string_literal: true

require_relative '../error'
require_relative '../game_window'
require_relative '../lease'
require_relative '../modals'
require_relative '../x11'

module Cdctl
  module Input
    # What must hold at the moment of a send. Nothing here trusts an earlier look: the lease can be
    # taken over, the game can restart, and a dialog can open between two key presses.
    class Guard
      NESTED = 'the game runs inside a nested compositor, which hides whether it has the focus outside'
      DIALOG_STEPS = ['Tell the person using this machine. Never answer, dismiss or work around it.'].freeze

      attr_reader :not_verified

      def initialize(connection:, process:, window:, lease:, token:, proc_root:, compositor:, ignored:,
                     allow_unverified:)
        @connection = connection
        @process = process
        @window = window
        @lease = lease
        @token = token
        @proc_root = proc_root
        @compositor = compositor
        @ignored = ignored
        @allow_unverified = allow_unverified
        @not_verified = []
      end

      def before_send!
        @lease.verify!(@token)
        same_process!
        same_geometry!
        focused!
        no_dialog!
      end

      # The cheap part, which can run many times during one key press.
      def during_hold!
        same_process!
        focused!
      end

      def dialogs_checked! = no_dialog!

      private

      def same_process!
        return if Lease.start_ticks(@proc_root, @process.pid) == @process.start_ticks

        raise Error.new('the game process is not the one observed', code: 'TARGET_CHANGED',
                                                                    next_steps: ['Run cdctl observe again.'])
      end

      def same_geometry!
        size = @connection.geometry(@window.id)
        now = [*@connection.position_on_root(@window.id), size.width, size.height]
        return if now == [@window.x, @window.y, @window.width, @window.height]

        raise Error.new("the window changed to #{now[2]}x#{now[3]}+#{now[0]}+#{now[1]}", code: 'RESOLUTION_CHANGED',
                                                                                         next_steps: observe_again)
      rescue X11::RequestError
        raise Error.new('the game window closed', code: 'TARGET_CHANGED', next_steps: observe_again)
      end

      def observe_again = ['Run cdctl observe again before using any coordinate.']

      def focused!
        return if WindowFinder.focus_within?(@connection, @window.id)

        raise Error.new('the game window does not have the focus', code: 'FOCUS_LOST',
                                                                   next_steps: ['Nothing was sent after this point. ' \
                                                                                'Ask the person, then try again.'])
      end

      def no_dialog!
        return unverified(NESTED) if @process.nested?

        state = @compositor.call
        if state.available? && !state.game_active
          raise Error.new('another window is active', code: 'FOCUS_LOST',
                                                      next_steps: ['It may be a dialog. Ask the person.'])
        end
        judge_dialogs(Modals.assess(state, ignored: @ignored, pid: @process.pid))
      end

      def judge_dialogs(modals)
        case modals[:status]
        when 'clear' then nil
        when 'present'
          names = modals[:blocking].map { it[:namespace] }.join(', ')
          raise Error.new("a system surface is over the game: #{names}", code: 'SYSTEM_DIALOG_PRESENT',
                                                                         next_steps: DIALOG_STEPS)
        else unverified(modals[:reason])
        end
      end

      def unverified(reason)
        @not_verified |= ['system_dialogs']
        return if @allow_unverified

        raise Error.new("no input was sent, because a system dialog cannot be ruled out: #{reason}",
                        code: 'SYSTEM_DIALOG_PRESENT', next_steps: [
                          'Check the screen with the person. --allow-unverified-dialogs sends anyway, and the ' \
                          'result lists system_dialogs under not_verified.'
                        ])
      end
    end
  end
end
