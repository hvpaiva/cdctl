# frozen_string_literal: true

module Cdctl
  module Recognition
    # A reduced picture of one part of the screen, in one channel: a small grid of averages, with no
    # recognizable detail and no game pixels. Comparing grids by correlation ignores overall
    # brightness and contrast, so the same label still matches over a lighter or darker background.
    #
    # Luma sees text and icons. Warm sees how much redder than blue a pixel is, which is what tells
    # the gold of a selected entry from the white of the others, whatever is behind them.
    module Signature
      CHANNELS = %w[luma warm].freeze
      # Below this spread a grid is flat. Correlation scales any noise up to full contrast, so without
      # this a nearly black frame can match a label. Each side has to clear it on its own.
      MIN_SPREAD = 3.0

      module_function

      def of(frame, rect, grid, channel)
        cols, rows = grid
        sums = Array.new(cols * rows, 0)
        counts = Array.new(cols * rows, 0)
        read = reader(frame, channel)
        pixels = frame.pixels
        each_pixel(frame, rect) do |at, dx, dy|
          cell = ((dy * rows / rect[3]) * cols) + (dx * cols / rect[2])
          sums[cell] += read.call(pixels, at)
          counts[cell] += 1
        end
        sums.each_with_index.map { |sum, index| counts[index].zero? ? 0 : sum / counts[index] }
      end

      # From -1 to 1. Zero when either side is flat, since then nothing can be compared.
      def correlation(one, other)
        return 0.0 unless one.size == other.size && !one.empty?

        a = centered(one)
        b = centered(other)
        floor = MIN_SPREAD * MIN_SPREAD * one.size
        energy_a = dot(a, a)
        energy_b = dot(b, b)
        return 0.0 if energy_a < floor || energy_b < floor

        dot(a, b) / Math.sqrt(energy_a * energy_b)
      end

      def each_pixel(frame, rect)
        x0, y0, width, height = rect
        stride = frame.stride
        step = frame.bytes_per_pixel
        height.times do |dy|
          base = ((y0 + dy) * stride) + (x0 * step)
          width.times { |dx| yield(base + (dx * step), dx, dy) }
        end
      end
      private_class_method :each_pixel

      def centered(values)
        mean = values.sum.to_f / values.size
        values.map { it - mean }
      end
      private_class_method :centered

      def dot(one, other)
        total = 0.0
        one.each_index { total += one[it] * other[it] }
        total
      end
      private_class_method :dot

      # Offsets of red and blue for each byte layout. Green carries most of luma, and a fixed-point
      # sum keeps this loop free of floats.
      def reader(frame, channel)
        red, green, blue = frame.layout == :bgrx ? [2, 1, 0] : [0, 1, 2]
        return ->(bytes, at) { [bytes.getbyte(at + red) - bytes.getbyte(at + blue), 0].max } if channel == 'warm'

        lambda do |bytes, at|
          ((bytes.getbyte(at + red) * 77) + (bytes.getbyte(at + green) * 150) + (bytes.getbyte(at + blue) * 29)) >> 8
        end
      end
      private_class_method :reader
    end
  end
end
