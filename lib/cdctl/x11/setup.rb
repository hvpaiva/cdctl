# frozen_string_literal: true

module Cdctl
  module X11
    Visual = Data.define(:id, :red_mask, :green_mask, :blue_mask)
    Screen = Data.define(:root, :width, :height, :root_visual, :root_depth, :visuals)

    # The server's description of itself, sent once when a client connects.
    Setup = Data.define(:resource_base, :resource_mask, :image_byte_order, :pixmap_formats, :screens) do
      def self.parse(body)
        resource_base, resource_mask = body[4, 8].unpack('VV')
        vendor_length = body[16, 2].unpack1('v')
        screen_count, format_count, image_byte_order = body[20, 3].unpack('CCC')
        offset = 32 + ((vendor_length + 3) & ~3)
        pixmap_formats = (0...format_count).to_h do |index|
          depth, bits_per_pixel = body[offset + (index * 8), 2].unpack('CC')
          [depth, bits_per_pixel]
        end
        offset += format_count * 8
        screens = Array.new(screen_count) do
          screen, offset = read_screen(body, offset)
          screen
        end
        new(resource_base:, resource_mask:, image_byte_order:, pixmap_formats:, screens:)
      end

      def self.read_screen(body, offset)
        root = body[offset, 4].unpack1('V')
        width, height = body[offset + 20, 4].unpack('vv')
        root_visual = body[offset + 32, 4].unpack1('V')
        root_depth, depth_count = body[offset + 38, 2].unpack('CC')
        visuals, cursor = read_depths(body, offset + 40, depth_count)
        [Screen.new(root:, width:, height:, root_visual:, root_depth:, visuals:), cursor]
      end
      private_class_method :read_screen

      def self.read_depths(body, cursor, count)
        visuals = []
        count.times do
          visual_count = body[cursor + 2, 2].unpack1('v')
          cursor += 8
          visual_count.times do
            id, red_mask, green_mask, blue_mask = body[cursor, 20].unpack('VxxxxVVV')
            visuals << Visual.new(id:, red_mask:, green_mask:, blue_mask:)
            cursor += 24
          end
        end
        [visuals, cursor]
      end
      private_class_method :read_depths

      def bits_per_pixel(depth) = pixmap_formats[depth]

      def least_significant_byte_first? = image_byte_order.zero?
    end
  end
end
