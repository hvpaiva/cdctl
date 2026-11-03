# frozen_string_literal: true

module Cdctl
  module Capture
    # Raw pixels, top row first. `pixels` is one binary String, so cropping copies rows, not pixels.
    Frame = Data.define(:width, :height, :layout, :pixels) do
      def bytes_per_pixel = Frame::BYTES_PER_PIXEL.fetch(layout)

      def stride = width * bytes_per_pixel

      def crop(x, y, w, h)
        rows = Array.new(h) { pixels.byteslice(((y + it) * stride) + (x * bytes_per_pixel), w * bytes_per_pixel) }
        with(width: w, height: h, pixels: rows.join)
      end

      def each_rgb_row
        return enum_for(:each_rgb_row) unless block_given?

        height.times do |row|
          line = pixels.byteslice(row * stride, stride)
          yield(layout == :rgb ? line : Frame.swizzle(line))
        end
      end

      # A fully black frame is what some capture paths return for a surface they cannot read, and
      # also what a loading screen looks like, so this only raises suspicion.
      def blank?
        step = bytes_per_pixel * Frame::SAMPLE_STEP
        (0...pixels.bytesize).step(step).none? do |index|
          pixels.getbyte(index) > Frame::BLACK_LEVEL || pixels.getbyte(index + 1) > Frame::BLACK_LEVEL ||
            pixels.getbyte(index + 2) > Frame::BLACK_LEVEL
        end
      end

      def self.swizzle(bgrx)
        source = bgrx.unpack('C*')
        target = Array.new((source.size / 4) * 3)
        read = 0
        write = 0
        while read < source.size
          target[write] = source[read + 2]
          target[write + 1] = source[read + 1]
          target[write + 2] = source[read]
          read += 4
          write += 3
        end
        target.pack('C*')
      end
    end
    Frame::BYTES_PER_PIXEL = { bgrx: 4, rgb: 3 }.freeze
    Frame::SAMPLE_STEP = 997
    Frame::BLACK_LEVEL = 12
  end
end
