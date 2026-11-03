# frozen_string_literal: true

require 'time'
require_relative '../error'
require_relative '../x11'
require_relative 'sentinel'

module Cdctl
  module Input
    # Sends one gesture at a time, in the only order that keeps the promise: check, write down what
    # is about to be held, arm the sentinel, press, watch, release, confirm. The release is in an
    # ensure block with signals held back, and a release that cannot be sent is left to the sentinel.
    class Sender
      # How often a hold looks at the focus and at other input.
      POLL = 0.02
      # A dialog takes a process start to check, so a hold looks for one less often.
      DIALOG_POLL = 0.25

      attr_reader :actions

      def initialize(connection:, guard:, activity:, journal:, sentinel:, journal_base:, actions: [])
        @connection = connection
        @guard = guard
        @activity = activity
        @journal = journal
        @sentinel = sentinel
        @journal_base = journal_base
        @actions = actions
      end

      def press(item, hold:, description:)
        @guard.before_send!
        nothing_else_held!
        @activity.check!
        cover([item], hold)
        pressed_at = Time.now
        begin
          send_item(item, down: true)
          hold_for(hold)
        ensure
          # A signal here would skip the release, so it waits until the key is up.
          Thread.handle_interrupt(SignalException => :never) { finish_hold(item, description, pressed_at) }
        end
        raise_trouble(@sentinel.trouble)
        confirm_released(item)
      end

      def move(x, y, description:)
        @guard.before_send!
        nothing_else_held!
        @activity.check!
        @activity.sent
        @connection.fake_motion(x, y)
        @actions << description.merge(at: Time.now.iso8601(3))
      end

      def pause(seconds)
        finish = now + seconds
        while (left = finish - now).positive?
          @activity.wait([left, POLL].min)
        end
      end

      private

      def nothing_else_held!
        keys = @connection.keys_held.size
        buttons = @connection.pointer.buttons_down
        return if keys.zero? && buttons.zero?

        raise Error.new("#{keys} key(s) and #{buttons.zero? ? 'no' : 'some'} button(s) are already held",
                        code: 'USER_INTERFERENCE', details: { keys:, buttons: !buttons.zero? },
                        next_steps: ['The person may be using the game. Ask them, and try again later. If nothing ' \
                                     'is being held, run cdctl input release.'])
      end

      def cover(items, hold)
        @journal.write(@journal_base.merge(held: items, pressed_at: Time.now.iso8601(3)))
        @sentinel.arm(items, hold)
      rescue Sentinel::Unavailable => e
        @journal.clear
        raise Error.new("nothing was sent: #{e.message}", code: 'PRECONDITION_FAILED')
      end

      def send_item(item, down:)
        @activity.sent
        if item[:kind] == 'key'
          @connection.fake_key(item[:code], down:)
        else
          @connection.fake_button(item[:code], down:)
        end
      end

      def hold_for(seconds)
        finish = now + seconds
        next_dialog_check = now + DIALOG_POLL
        while (left = finish - now).positive?
          @activity.wait([left, POLL].min)
          raise_trouble(@sentinel.trouble)
          @guard.during_hold!
          next unless now >= next_dialog_check

          @guard.dialogs_checked!
          next_dialog_check = now + DIALOG_POLL
        end
      end

      def raise_trouble(trouble)
        return unless trouble

        raise Error.new('the process that guarantees the release is gone', code: 'INTERNAL_ERROR') if trouble == :gone

        raise Error.new('the hold outlived its deadline, and the sentinel released it', code: 'TIMEOUT')
      end

      def finish_hold(item, description, pressed_at)
        released_by = release(item)
      ensure
        released_at = Time.now
        @actions << description.merge(held_ms: ((released_at - pressed_at) * 1000).round,
                                      pressed_at: pressed_at.iso8601(3), released_at: released_at.iso8601(3),
                                      released_by: released_by || 'sentinel')
      end

      # Never raises: this runs in an ensure block, on the way out of whatever went wrong. A sentinel
      # that is gone has nothing left to do once the release is sent. If that release cannot be sent
      # either, the journal stays, and the next command finishes the job.
      def release(item)
        expired = @sentinel.expired?
        send_item(item, down: false)
        @journal.clear
        disarm_sentinel
        expired || @sentinel.expired? ? 'sentinel' : 'cdctl'
      rescue X11::Error, SystemCallError
        @sentinel.abandon
        @journal.read ? 'next_command' : 'sentinel'
      end

      def disarm_sentinel
        @sentinel.disarm
      rescue Sentinel::Unavailable
        nil
      end

      def confirm_released(item)
        still_down = if item[:kind] == 'key'
                       @connection.keys_held.include?(item[:code])
                     else
                       @connection.button_down?(item[:code])
                     end
        return unless still_down

        raise Error.new('the release was sent and the key or button is still down, which means something else ' \
                        'is holding it too', code: 'USER_INTERFERENCE',
                                             next_steps: ['Ask the person, and run cdctl input release if nobody is.'])
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
