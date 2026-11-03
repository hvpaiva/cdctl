# frozen_string_literal: true

require_relative 'frame'

module Cdctl
  module Capture
    # The raw form screen grabbers can write. It needs no decompression, which keeps a decoder fast.
    module Ppm
      class ParseError < StandardError; end

      HEADER = /\AP6\s+(?:#[^\n]*\n\s*)*(\d+)\s+(?:#[^\n]*\n\s*)*(\d+)\s+(?:#[^\n]*\n\s*)*(\d+)\s/n
      MAX_VALUE = 255

      def self.parse(bytes)
        match = HEADER.match(bytes)
        raise ParseError, 'not a binary PPM image' unless match

        width, height, maximum = match.captures.map(&:to_i)
        raise ParseError, "unsupported PPM maximum #{maximum}" unless maximum == MAX_VALUE

        pixels = bytes.byteslice(match.end(0), width * height * 3)
        raise ParseError, 'the PPM image is truncated' unless pixels.to_s.bytesize == width * height * 3

        Frame.new(width:, height:, layout: :rgb, pixels:)
      end
    end
  end
end
