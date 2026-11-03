# frozen_string_literal: true

module Cdctl
  module X11
    # Sending input and reading what is held. XTEST reaches the X server, never the compositor, so a
    # key sent here cannot trigger a desktop shortcut, and a motion moves only the X server's pointer.
    module XTest
      Pointer = Data.define(:x, :y, :mask) do
        def buttons_down = mask & XTest::BUTTON_MASKS
      end

      FAKE_INPUT = 2
      KEY_PRESS = 2
      KEY_RELEASE = 3
      BUTTON_PRESS = 4
      BUTTON_RELEASE = 5
      MOTION = 6
      BUTTON_MASKS = 0x1F00
      FIRST_BUTTON_BIT = 8

      def xtest? = !extension('XTEST').nil?

      def fake_key(keycode, down:) = fake(down ? KEY_PRESS : KEY_RELEASE, keycode)

      def fake_button(button, down:) = fake(down ? BUTTON_PRESS : BUTTON_RELEASE, button)

      def fake_motion(x, y) = fake(MOTION, 0, x:, y:)

      def button_down?(button) = pointer.mask[FIRST_BUTTON_BIT + button - 1] == 1

      # Whose keys they are is not in this reply and is not asked for: a caller compares them only
      # with what it pressed itself.
      def keys_held
        reply = exchange([44, 0, 1].pack('CCv'))[8, 32]
        reply.bytes.each_with_index.flat_map do |byte, index|
          (0..7).select { byte[it] == 1 }.map { (index * 8) + it }
        end
      end

      def pointer
        reply = exchange([38, 0, 2, screen.root].pack('CCvV'))
        x, y = reply[16, 4].unpack('s<s<')
        Pointer.new(x:, y:, mask: reply[24, 2].unpack1('v'))
      end

      # The keycode that produces this symbol without a modifier, or nil.
      def keycode_for(keysym) = keyboard_symbols[keysym]

      private

      def fake(type, detail, x: 0, y: 0)
        major = extension('XTEST').major_opcode
        checked_request([major, FAKE_INPUT, 9, type, detail, 0, 0, 0, 0, 0, x, y, 0, 0, 0, 0]
                        .pack('CCvCCvVVVVs<s<VvCC'))
      end

      # Only the first two columns: the rest need a group switch, which nothing here sends.
      def keyboard_symbols
        @keyboard_symbols ||= begin
          first = setup.min_keycode
          count = setup.max_keycode - first + 1
          reply = exchange([101, 0, 2, first, count, 0].pack('CCvCCv'))
          width = reply.getbyte(1)
          reply.byteslice(32..).unpack('V*').each_slice(width).with_index.with_object({}) do |(row, index), found|
            row.first(2).each { found[it] ||= first + index unless it.zero? }
          end
        end
      end
    end
  end
end
