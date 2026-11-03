# frozen_string_literal: true

require_relative '../cli/errors'
require_relative '../error'

module Cdctl
  module Capture
    # A rectangle in window coordinates. Named regions need a UI profile, so only numbers exist here.
    Region = Data.define(:x, :y, :width, :height) do
      def self.parse(text)
        match = /\A(\d{1,5}),(\d{1,5}),(\d{1,5}),(\d{1,5})\z/.match(text.to_s)
        raise CLI::UsageError, "invalid region #{text.inspect}: expected X,Y,WIDTH,HEIGHT in window pixels" unless match

        new(x: match[1].to_i, y: match[2].to_i, width: match[3].to_i, height: match[4].to_i)
      end

      def self.whole(window) = new(x: 0, y: 0, width: window.width, height: window.height)

      def check_inside(window)
        fits = width.positive? && height.positive? && x + width <= window.width && y + height <= window.height
        return self if fits

        raise Error.new("region #{x},#{y},#{width},#{height} is outside the #{window.width}x#{window.height} window",
                        code: 'PRECONDITION_FAILED', next_steps: ['Read the window size from cdctl status and retry.'])
      end

      def to_h = { space: 'window', x:, y:, width:, height: }

      def absolute(window) = { x: window.x + x, y: window.y + y, width:, height: }
    end
  end
end
