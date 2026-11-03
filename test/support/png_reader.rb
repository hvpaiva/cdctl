# frozen_string_literal: true

require 'zlib'

# Reads back what Capture::Png writes, so a test checks the file instead of the encoder's inputs.
module PngReader
  Image = Data.define(:width, :height, :rows) do
    def pixel(x, y) = rows[y].byteslice(x * 3, 3).unpack('CCC')
  end

  module_function

  def read(bytes)
    raise ArgumentError, 'not a PNG' unless bytes.start_with?("\x89PNG\r\n\x1A\n".b)

    chunks = chunks(bytes)
    width, height = chunks.fetch('IHDR').unpack('NN')
    raw = Zlib.inflate(chunks.fetch('IDAT'))
    stride = (width * 3) + 1
    Image.new(width:, height:, rows: Array.new(height) { raw.byteslice((it * stride) + 1, stride - 1) })
  end

  def chunks(bytes)
    offset = 8
    found = {}
    while offset < bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1('N')
      found[bytes.byteslice(offset + 4, 4)] = bytes.byteslice(offset + 8, length)
      offset += 12 + length
    end
    found
  end
end
