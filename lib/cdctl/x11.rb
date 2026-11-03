# frozen_string_literal: true

module Cdctl
  # A small X11 client over the Unix socket, in Ruby alone. The game draws through X on every
  # Proton setup that does not opt into native Wayland, whatever the desktop is, so this one path
  # covers GNOME, KDE, wlroots compositors, plain X sessions and a nested gamescope. Capture and
  # coordinates also share one pixel space, which spares every compositor's scaling rules.
  module X11
    class Error < StandardError; end
    class ConnectError < Error; end
    class TimeoutError < Error; end
    class ClosedError < Error; end

    class RequestError < Error
      BAD_WINDOW = 3
      BAD_MATCH = 8
      NAMES = { 1 => 'BadRequest', 2 => 'BadValue', 3 => 'BadWindow', 4 => 'BadPixmap', 5 => 'BadAtom',
                8 => 'BadMatch', 9 => 'BadDrawable', 10 => 'BadAccess', 11 => 'BadAlloc', 16 => 'BadLength' }.freeze

      attr_reader :error_code, :major_opcode

      def initialize(error_code, major_opcode)
        @error_code = error_code
        @major_opcode = major_opcode
        super("X server answered #{NAMES.fetch(error_code, "error #{error_code}")} to request #{major_opcode}")
      end
    end

    # What a DISPLAY value says, for the forms that reach a local socket. A remote display would
    # carry the game's frames over the network, which nothing here asks for.
    module Display
      Address = Data.define(:number, :screen)
      PATTERN = /\A(?:unix)?:(\d+)(?:\.(\d+))?\z/

      def self.parse(value)
        match = PATTERN.match(value.to_s)
        raise ConnectError, "unsupported DISPLAY #{value.inspect}: only local displays are used" unless match

        Address.new(number: match[1].to_i, screen: match[2].to_i)
      end
    end
  end
end
