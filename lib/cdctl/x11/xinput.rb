# frozen_string_literal: true

module Cdctl
  module X11
    # XI2 raw events say which device an event came from, which is how input from a person is told
    # apart from input sent through XTEST. An event also holds the keycode, and that is never read:
    # only its type and its source device leave this module.
    module XInput
      Device = Data.define(:id, :use, :name) do
        def xtest? = name.include?('XTEST')
      end
      RawEvent = Data.define(:kind, :source)

      NAME = 'XInputExtension'
      SELECT_EVENTS = 46
      QUERY_VERSION = 47
      QUERY_DEVICE = 48
      ALL_DEVICES = 0
      ALL_MASTER_DEVICES = 1
      MASTER_POINTER = 1
      MASTER_KEYBOARD = 2
      WANTED_MAJOR = 2
      WANTED_MINOR = 3
      KINDS = { 13 => :key_press, 14 => :key_release, 15 => :button_press, 16 => :button_release, 17 => :motion }.freeze

      # The server answers with the version both sides support. Asking is also what turns XI2 on.
      def xi2_version
        major = extension(NAME)&.major_opcode
        return nil unless major

        reply = exchange([major, QUERY_VERSION, 2, WANTED_MAJOR, WANTED_MINOR].pack('CCvvv'))
        reply[8, 4].unpack('vv')
      end

      def xi2_devices
        reply = exchange([extension(NAME).major_opcode, QUERY_DEVICE, 2, ALL_DEVICES, 0].pack('CCvvv'))
        offset = 32
        Array.new(reply[8, 2].unpack1('v')) do
          device, offset = read_device(reply, offset)
          device
        end
      end

      def select_raw_events
        mask = KINDS.keys.sum { 1 << it }
        body = [screen.root, 1, 0, ALL_MASTER_DEVICES, 1, mask].pack('VvvvvV')
        checked_request([extension(NAME).major_opcode, SELECT_EVENTS, 1 + (body.bytesize / 4)].pack('CCv') + body)
      end

      # The next raw event, or nil when none arrives in time.
      def next_raw_event(timeout)
        major = extension(NAME).major_opcode
        deadline = monotonic_now + timeout
        loop do
          remaining = deadline - monotonic_now
          event = next_event([remaining, 0].max)
          return nil unless event
          next unless event.getbyte(1) == major

          kind = KINDS[event[8, 2].unpack1('v')]
          return RawEvent.new(kind:, source: event[20, 2].unpack1('v')) if kind
        end
      end

      private

      def read_device(reply, offset)
        id, use, _attachment, classes, name_length = reply[offset, 12].unpack('vvvvv')
        name = reply[offset + 12, name_length].to_s
        offset += 12 + ((name_length + 3) & ~3)
        classes.times { offset += reply[offset + 2, 2].unpack1('v') * 4 }
        [Device.new(id:, use:, name:), offset]
      end
    end
  end
end
