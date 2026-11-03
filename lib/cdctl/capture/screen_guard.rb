# frozen_string_literal: true

require_relative '../modals'

module Cdctl
  module Capture
    class Unusable < StandardError; end

    # A backend that reads the composited screen records whatever is on top of the game, including
    # a password prompt or a notification. A state read earlier says nothing about the moment the
    # pixels were taken, so each use is bracketed by two fresh looks at the compositor, and a frame
    # is kept only if both prove the game alone was on that rectangle.
    class ScreenGuard
      def initialize(observe:, ignored:, pid:)
        @observe = observe
        @ignored = ignored
        @pid = pid
      end

      def check!(window, region)
        compositor = @observe.call
        refuse('needs a compositor driver to prove the game is on top') unless compositor.available?

        modals = Modals.assess(compositor, ignored: @ignored, pid: @pid)
        refuse("would capture other surfaces: #{why(modals)}") unless modals[:status] == 'clear'
        refuse('cannot trust its coordinates: the compositor and X11 place the game differently') unless
          same_place?(compositor.game_client, window)

        covering = modals[:ignored].select { Modals.overlap?(it, region.absolute(window)) }
        refuse("would capture #{covering.map { it[:namespace] }.join(', ')}") unless covering.empty?
      end

      private

      def refuse(problem) = raise(Unusable, "a capture of the screen #{problem}")

      def why(modals)
        names = modals[:blocking].map { it[:namespace] }
        names.empty? ? modals[:reason] : names.join(', ')
      end

      # Compositor coordinates and X coordinates agree only when the game is not nested or scaled.
      def same_place?(client, window)
        return false unless client

        [client[:x], client[:y], client[:width], client[:height]] == [window.x, window.y, window.width, window.height]
      end
    end
  end
end
