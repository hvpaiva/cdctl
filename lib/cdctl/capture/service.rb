# frozen_string_literal: true

require 'time'
require_relative '../error'
require_relative '../shell'
require_relative '../x11'
require_relative 'frame'
require_relative 'ppm'
require_relative 'region'
require_relative 'screen_guard'

module Cdctl
  module Capture
    Shot = Data.define(:frame, :backend, :captured_at, :region, :absolute, :blank_suspected, :fallback_reason,
                       :source_size) do
      def pixel_scale = (frame.width.to_f / region.width).round(4)
    end

    # Takes one frame of the game window and proves the geometry held while it was taken. Reading
    # the window itself shows only the game wherever an X compositing manager keeps windows apart.
    # grim reads the composited screen instead, so it runs only under the ScreenGuard.
    class Service
      BACKENDS = %w[auto x11 grim].freeze
      X11_BACKEND = 'x11_get_image'
      GRIM_BACKEND = 'grim'
      GRIM_TIMEOUT = 10.0

      # Why X11 cannot capture this window, or nil. It asks for one real pixel, since a server can
      # answer for a pixel format that cdctl cannot read.
      def self.x11_problem(connection, window)
        unless connection.pixel_layout(window.depth, window.visual)
          return "the window uses a pixel format cdctl cannot read (depth #{window.depth})"
        end

        connection.image(window.id, 0, 0, 1, 1)
        nil
      rescue X11::Error => e
        e.message
      end

      def initialize(connection:, shell:, guard:)
        @connection = connection
        @shell = shell
        @guard = guard
      end

      def take(window, region: nil, backend: 'auto')
        target = (region || Region.whole(window)).check_inside(window)
        shot = attempt(window, target, backend)
        confirm_geometry(window)
        shot
      rescue X11::TimeoutError => e
        raise Error.new("capture failed: #{e.message}", code: 'TIMEOUT')
      rescue X11::ClosedError => e
        raise Error.new("capture failed: #{e.message}", code: 'CAPTURE_FAILED')
      end

      private

      def attempt(window, region, backend)
        case backend
        when 'x11' then from_x11(window, region)
        when 'grim' then from_grim(window, region)
        else automatic(window, region)
        end
      rescue Unusable => e
        raise Error.new(e.message, code: 'UNSUPPORTED_BACKEND')
      end

      def automatic(window, region)
        shot = from_x11(window, region)
        shot.blank_suspected ? better_than_blank(shot, window, region) : shot
      rescue Unusable => e
        fall_back(window, region, e.message)
      end

      def fall_back(window, region, x11_problem)
        from_grim(window, region, fallback_reason: x11_problem)
      rescue Unusable => e
        raise Unusable, "#{x11_problem}; #{e.message}"
      end

      # A black frame can be a real loading screen, so it stands unless grim shows otherwise.
      def better_than_blank(shot, window, region)
        other = from_grim(window, region, fallback_reason: 'the X11 frame was black')
        other.blank_suspected ? shot : other
      rescue Unusable
        shot
      end

      def from_x11(window, region)
        layout = @connection.pixel_layout(window.depth, window.visual)
        raise Unusable, "the window uses a pixel format cdctl cannot read (depth #{window.depth})" unless layout

        image = @connection.image(window.id, region.x, region.y, region.width, region.height)
        frame = Frame.new(width: region.width, height: region.height, layout:, pixels: image.data)
        shot(frame, X11_BACKEND, window, region, nil)
      rescue X11::RequestError => e
        raise Unusable, "the X server refused the capture (#{e.message}); the window may be hidden"
      end

      def from_grim(window, region, fallback_reason: nil)
        @guard.check!(window, region)
        geometry = "#{window.x + region.x},#{window.y + region.y} #{region.width}x#{region.height}"
        output = @shell.run('grim', '-t', 'ppm', '-g', geometry, '-', timeout: GRIM_TIMEOUT)
        raise Unusable, "grim failed: #{output.stderr.strip}" unless output.success?

        @guard.check!(window, region)
        shot(Ppm.parse(output.stdout), GRIM_BACKEND, window, region, fallback_reason)
      rescue Shell::NotAvailable, Shell::TimedOut, Ppm::ParseError => e
        raise Unusable, "grim is not usable: #{e.message}"
      end

      def shot(frame, backend, window, region, fallback_reason)
        Shot.new(frame:, backend:, captured_at: Time.now.iso8601(3), region:, absolute: region.absolute(window),
                 blank_suspected: frame.blank?, fallback_reason:,
                 source_size: { width: window.width, height: window.height })
      end

      def confirm_geometry(window)
        size = @connection.geometry(window.id)
        now = [*@connection.position_on_root(window.id), size.width, size.height]
        was = [window.x, window.y, window.width, window.height]
        return if now == was

        raise Error.new("the window changed from #{describe(was)} to #{describe(now)} during the capture; " \
                        'the frame was discarded',
                        code: 'RESOLUTION_CHANGED', next_steps: ['Observe again before using any coordinate.'])
      rescue X11::RequestError
        raise Error.new('the game window closed during the capture', code: 'TARGET_CHANGED')
      end

      def describe((x, y, width, height)) = "#{width}x#{height}+#{x}+#{y}"
    end
  end
end
