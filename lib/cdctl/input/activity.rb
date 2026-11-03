# frozen_string_literal: true

require_relative '../error'
require_relative '../x11'

module Cdctl
  module Input
    # Whether anything else is sending input right now. It counts events per source device, and
    # never looks at which key: this must not be able to log what a person types.
    #
    # A person shows up as a device other than XTEST. Another program using XTEST shows up as more
    # XTEST events than this process sent.
    class Activity
      # A hand resting on a mouse makes a few events. A key or a button is always deliberate.
      MOTION_TOLERANCE = 3
      NOT_WATCHED = 'this X server does not report input per device, so only held keys and buttons are checked'

      attr_reader :not_watched_reason

      def self.open(opener)
        connection = opener.call
        new(connection)
      rescue X11::Error => e
        connection&.close
        new(nil, reason: e.message)
      end

      def initialize(connection, reason: nil)
        @connection = connection
        @not_watched_reason = reason
        @own_sent = 0
        @xtest_seen = 0
        @foreign = Hash.new(0)
        start if connection
      end

      def close = @connection&.close

      def watching? = !@connection.nil?

      def sent(count = 1)
        @own_sent += count
      end

      def counts = { key_press: @foreign[:key_press], button_press: @foreign[:button_press], motion: @foreign[:motion] }

      # Sleeps up to `seconds`, waking at once if an event arrives, and raises if one is not ours.
      def wait(seconds)
        return sleep(seconds) unless watching?

        take(@connection.next_raw_event(seconds))
        drain
        judge
      end

      def check!
        return unless watching?

        drain
        judge
      end

      private

      def start
        version = @connection.xi2_version
        return stop(NOT_WATCHED) unless version&.first.to_i >= 2

        @xtest_devices = @connection.xi2_devices.select(&:xtest?).map(&:id)
        @connection.select_raw_events
      rescue X11::Error => e
        stop(e.message)
      end

      def stop(reason)
        @connection&.close
        @connection = nil
        @not_watched_reason = reason
      end

      def drain
        while (event = @connection.next_raw_event(0))
          take(event)
        end
      end

      def take(event)
        return unless event

        if @xtest_devices.include?(event.source)
          @xtest_seen += 1
        else
          @foreign[event.kind] += 1
        end
      end

      def judge
        interfering = @foreign[:key_press] + @foreign[:button_press]
        too_much_motion = @foreign[:motion] > MOTION_TOLERANCE
        extra = @xtest_seen - @own_sent
        return unless interfering.positive? || too_much_motion || extra.positive?

        raise Error.new(message(interfering, extra), code: 'USER_INTERFERENCE',
                                                     details: counts.merge(extra_xtest: extra),
                                                     next_steps: ['Tell the person using this machine, and try later.'])
      end

      def message(interfering, extra)
        return 'another program is sending input through XTEST' if interfering.zero? && extra.positive?

        'input arrived from a person or another device during the operation'
      end
    end
  end
end
