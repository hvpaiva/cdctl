# frozen_string_literal: true

require 'socket'
require_relative '../x11'
require_relative 'setup'
require_relative 'requests'
require_relative 'randr'
require_relative 'xinput'
require_relative 'xtest'

module Cdctl
  module X11
    class Connection
      include Requests
      include RandR
      include XInput
      include XTest

      SOCKET_DIRECTORY = '/tmp/.X11-unix'
      DEFAULT_TIMEOUT = 2.0
      LEAST_SIGNIFICANT_BYTE_FIRST = 0x6C
      PROTOCOL_MAJOR = 11
      SCHEME = 'MIT-MAGIC-COOKIE-1'
      REPLY = 1
      FAILURE = 0
      GENERIC_EVENT = 35
      READ_CHUNK = 1 << 20
      ROUND_TRIP = [43, 0, 1].pack('CCv').freeze
      # A frame of the largest display a game can run on fits well under this.
      MAX_REPLY_BYTES = 1 << 30
      ROOT_UID = 0

      attr_reader :setup, :screen, :display

      # Tries each cookie and then no credential at all, since a local session often authorizes
      # the user rather than a cookie. The server's refusal text never holds the cookie.
      def self.open(display, cookies: [], timeout: DEFAULT_TIMEOUT, socket_directory: SOCKET_DIRECTORY)
        address = Display.parse(display)
        refusals = []
        [*cookies, nil].uniq.each do |cookie|
          socket = open_socket(address, socket_directory)
          connection = attempt(socket, refusals) do
            verify_peer(socket, address.number)
            new(socket, address, cookie, timeout, display)
          end
          return connection if connection
        end
        raise ConnectError, "X server #{display} refused the connection: #{refusals.uniq.join('; ')}"
      end

      # A refusal is about this cookie, so the next one gets its turn. Anything else ends the attempt.
      def self.attempt(socket, refusals)
        yield
      rescue ConnectError => e
        socket.close
        refusals << e.message
        nil
      rescue Error
        socket.close
        raise
      end
      private_class_method :attempt

      # Any local user can bind an abstract socket, or create a filesystem one for a display number
      # nobody is using, and would then receive the cookie.
      def self.verify_peer(socket, number, own_uid: Process.euid)
        peer_uid, = socket.getpeereid
        return if [own_uid, ROOT_UID].include?(peer_uid)

        raise ConnectError, "X server #{number} belongs to another user (uid #{peer_uid}), so it gets no credential"
      end

      # A sandbox may hide the filesystem socket while the abstract one stays reachable.
      def self.open_socket(address, directory)
        path = File.join(directory, "X#{address.number}")
        UNIXSocket.new(path)
      rescue SystemCallError => e
        begin
          UNIXSocket.new("\0#{path}")
        rescue SystemCallError, ArgumentError
          raise ConnectError, "cannot reach X server #{address.number}: #{e.message.sub(/ - .*\z/m, '')}"
        end
      end
      private_class_method :open_socket

      def initialize(socket, address, cookie, timeout, display)
        @socket = socket
        @timeout = timeout
        @display = display
        @sequence = 0
        @atoms = {}
        @extensions = {}
        @setup = handshake(cookie)
        @screen = @setup.screens[address.screen] or raise ConnectError, "X server has no screen #{address.screen}"
      end

      def close = @socket.close

      def exchange(bytes, timeout: @timeout)
        deadline = now + timeout
        guarded do
          write_all(bytes, deadline)
          @sequence = (@sequence + 1) & 0xFFFF
          read_reply(@sequence, deadline)
        end
      end

      # A refusal of this request carries its sequence, and the next exchange skips it.
      def send_request(bytes, timeout: @timeout)
        deadline = now + timeout
        guarded do
          write_all(bytes, deadline)
          @sequence = (@sequence + 1) & 0xFFFF
        end
      end

      # A request with no reply can only be refused, so a round trip behind it shows whether it was,
      # and also that the server has processed it.
      def checked_request(bytes, timeout: @timeout)
        deadline = now + timeout
        guarded do
          write_all(bytes, deadline)
          refusable = @sequence = (@sequence + 1) & 0xFFFF
          write_all(ROUND_TRIP, deadline)
          @sequence = (@sequence + 1) & 0xFFFF
          read_reply(@sequence, deadline, refusable:)
        end
      end

      # For a connection that asked for events. Nil when none arrives in time.
      def next_event(timeout)
        guarded do
          next nil unless @socket.wait_readable(timeout)

          deadline = now + @timeout
          head = read_exact(32, deadline)
          kind = head.getbyte(0) & 0x7F
          kind == GENERIC_EVENT ? head + read_exact(head[4, 4].unpack1('V') * 4, deadline) : head
        end
      end

      def monotonic_now = now

      private

      # After a timeout part of a reply may still be on its way, and the next read would take those
      # bytes for the start of its own answer. The stream cannot be trusted again.
      def guarded
        raise @failure if @failure

        yield
      rescue TimeoutError, ClosedError => e
        @failure = e
        raise
      end

      def handshake(cookie)
        name = cookie ? SCHEME : ''
        data = cookie.to_s
        head = [LEAST_SIGNIFICANT_BYTE_FIRST, 0, PROTOCOL_MAJOR, 0, name.bytesize, data.bytesize, 0].pack('CCvvvvv')
        deadline = now + @timeout
        write_all(head + pad(name) + pad(data), deadline)
        status, reason_length, _major, _minor, extra = read_exact(8, deadline).unpack('CCvvv')
        body = read_exact(extra * 4, deadline)
        return Setup.parse(body) if status == REPLY

        reason = status == FAILURE ? body[0, reason_length] : body
        raise ConnectError, String.new(reason.to_s, encoding: Encoding::UTF_8).scrub.strip
      rescue ClosedError => e
        raise ConnectError, e.message
      end

      def read_reply(expected, deadline, refusable: nil)
        loop do
          head = read_exact(32, deadline)
          kind = head.getbyte(0)
          if kind == FAILURE
            raise RequestError.new(head.getbyte(1), head.getbyte(10)) if [expected,
                                                                          refusable].include?(sequence_of(head))

            next
          end
          next skip_generic_event(head, deadline) if kind & 0x7F == GENERIC_EVENT
          next unless kind == REPLY

          reply = complete_reply(head, deadline)
          return reply if sequence_of(head) == expected
        end
      end

      def sequence_of(head) = head[2, 2].unpack1('v')

      def complete_reply(head, deadline)
        bytes = head[4, 4].unpack1('V') * 4
        raise Error, "reply of #{bytes} bytes is larger than expected" if bytes > MAX_REPLY_BYTES

        bytes.positive? ? head + read_exact(bytes, deadline) : head
      end

      def skip_generic_event(head, deadline)
        bytes = head[4, 4].unpack1('V') * 4
        read_exact(bytes, deadline) if bytes.positive?
      end

      def write_all(bytes, deadline)
        offset = 0
        while offset < bytes.bytesize
          written = @socket.write_nonblock(bytes.byteslice(offset..), exception: false)
          if written == :wait_writable
            wait(deadline, write: true)
          else
            offset += written
          end
        end
      rescue Errno::EPIPE, Errno::ECONNRESET
        raise ClosedError, 'the X server closed the connection'
      end

      def read_exact(count, deadline)
        buffer = String.new(capacity: count, encoding: Encoding::BINARY)
        while buffer.bytesize < count
          chunk = @socket.read_nonblock([count - buffer.bytesize, READ_CHUNK].min, exception: false)
          case chunk
          when :wait_readable then wait(deadline)
          when nil then raise ClosedError, 'the X server closed the connection'
          else buffer << chunk
          end
        end
        buffer
      rescue Errno::ECONNRESET
        raise ClosedError, 'the X server closed the connection'
      end

      def wait(deadline, write: false)
        remaining = deadline - now
        ready = remaining.positive? && IO.select(write ? nil : [@socket], write ? [@socket] : nil, nil, remaining)
        raise TimeoutError, 'the X server did not answer in time' unless ready
      end

      def pad(text) = text.b + ("\0" * (-text.bytesize % 4))

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
