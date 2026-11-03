# frozen_string_literal: true

require_relative '../cli/errors'

module Cdctl
  module Input
    # Names follow X keysyms, the vocabulary any X tool uses. A letter stands for the key, not for an
    # upper or lower case character: nothing here adds a modifier.
    module Keys
      NAMED = {
        'Escape' => 0xFF1B, 'Return' => 0xFF0D, 'Tab' => 0xFF09, 'BackSpace' => 0xFF08, 'space' => 0x20,
        'Delete' => 0xFFFF, 'Insert' => 0xFF63, 'Home' => 0xFF50, 'End' => 0xFF57, 'Page_Up' => 0xFF55,
        'Page_Down' => 0xFF56, 'Left' => 0xFF51, 'Up' => 0xFF52, 'Right' => 0xFF53, 'Down' => 0xFF54,
        'Shift_L' => 0xFFE1, 'Shift_R' => 0xFFE2, 'Control_L' => 0xFFE3, 'Control_R' => 0xFFE4, 'Alt_L' => 0xFFE9,
        'Alt_R' => 0xFFEA, 'minus' => 0x2D, 'equal' => 0x3D, 'comma' => 0x2C, 'period' => 0x2E, 'slash' => 0x2F,
        'semicolon' => 0x3B, 'apostrophe' => 0x27, 'bracketleft' => 0x5B, 'bracketright' => 0x5D,
        'backslash' => 0x5C, 'grave' => 0x60
      }.freeze
      F1 = 0xFFBE
      FUNCTION_KEYS = 24
      BUTTONS = { 'left' => 1, 'middle' => 2, 'right' => 3 }.freeze
      WHEEL = { 'up' => 4, 'down' => 5 }.freeze

      module_function

      def keysym(name)
        known(name) or raise CLI::UsageError, "unknown key #{name.inspect}: use a letter, a digit, F1 to " \
                                              "F#{FUNCTION_KEYS}, or one of #{NAMED.keys.join(', ')}"
      end

      def known(name)
        return name.downcase.ord if name.match?(/\A[A-Za-z0-9]\z/)

        function = name[/\AF(\d{1,2})\z/, 1]&.to_i
        return F1 + function - 1 if function&.between?(1, FUNCTION_KEYS)

        NAMED[name]
      end
    end
  end
end
