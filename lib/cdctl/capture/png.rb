# frozen_string_literal: true

require 'zlib'

module Cdctl
  module Capture
    # A truecolor PNG writer, so a capture needs no image library. Zoom repeats whole pixels and
    # never interpolates: inspecting a capture must not invent detail.
    module Png
      SIGNATURE = "\x89PNG\r\n\x1A\n".b
      BIT_DEPTH = 8
      TRUECOLOR = 2
      NO_FILTER = "\0".b

      module_function

      def encode(frame, zoom: 1)
        header = [frame.width * zoom, frame.height * zoom, BIT_DEPTH, TRUECOLOR, 0, 0, 0].pack('NNCCCCC')
        SIGNATURE + chunk('IHDR', header) + chunk('IDAT', compress(frame, zoom)) + chunk('IEND', ''.b)
      end

      def compress(frame, zoom)
        deflate = Zlib::Deflate.new(Zlib::BEST_SPEED)
        data = String.new(encoding: Encoding::BINARY)
        frame.each_rgb_row do |row|
          line = NO_FILTER + (zoom > 1 ? widen(row, zoom) : row)
          zoom.times { data << deflate.deflate(line) }
        end
        data << deflate.finish
        deflate.close
        data
      end
      private_class_method :compress

      def widen(row, zoom)
        row.unpack("a3#{'a3' * ((row.bytesize / 3) - 1)}").map { it * zoom }.join
      end
      private_class_method :widen

      def chunk(type, data)
        [data.bytesize].pack('N') + type.b + data + [Zlib.crc32(type + data)].pack('N')
      end
      private_class_method :chunk
    end
  end
end
