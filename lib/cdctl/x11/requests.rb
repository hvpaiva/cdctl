# frozen_string_literal: true

module Cdctl
  module X11
    # The core protocol requests cdctl reads with. Each packs the request and picks fields out of
    # the 32-byte reply header at the offsets the X11 protocol document gives.
    module Requests
      Geometry = Data.define(:depth, :root, :x, :y, :width, :height)
      Tree = Data.define(:root, :parent, :children)
      Attributes = Data.define(:visual, :window_class, :map_state, :override_redirect) do
        def viewable? = map_state == Requests::VIEWABLE
      end
      Extension = Data.define(:major_opcode, :first_event, :first_error)
      Image = Data.define(:depth, :visual, :data)

      VIEWABLE = 2
      NO_FOCUS = 0
      POINTER_ROOT_FOCUS = 1
      Z_PIXMAP = 2
      ALL_PLANES = 0xFFFFFFFF
      PROPERTY_WORDS = 4096
      IMAGE_TIMEOUT = 10.0
      STRING_FORMAT = 8

      def input_focus = exchange([43, 0, 1].pack('CCv'))[8, 4].unpack1('V')

      def geometry(drawable)
        reply = exchange([14, 0, 2, drawable].pack('CCvV'))
        x, y, width, height = reply[12, 8].unpack('s<s<vv')
        Geometry.new(depth: reply.getbyte(1), root: reply[8, 4].unpack1('V'), x:, y:, width:, height:)
      end

      def tree(window)
        reply = exchange([15, 0, 2, window].pack('CCvV'))
        root, parent = reply[8, 8].unpack('VV')
        count = reply[16, 2].unpack1('v')
        Tree.new(root:, parent:, children: reply[32, count * 4].to_s.unpack('V*'))
      end

      def attributes(window)
        reply = exchange([3, 0, 2, window].pack('CCvV'))
        Attributes.new(visual: reply[8, 4].unpack1('V'), window_class: reply[12, 2].unpack1('v'),
                       map_state: reply.getbyte(26), override_redirect: reply.getbyte(27) == 1)
      end

      def position_on_root(window)
        reply = exchange([40, 0, 4, window, screen.root, 0, 0].pack('CCvVVs<s<'))
        reply[12, 4].unpack('s<s<')
      end

      # Zero when the server has never seen the name, in which case no window can hold it yet. Only
      # a real atom is remembered, since another client can create the name at any moment.
      def atom(name)
        return @atoms[name] if @atoms.key?(name)

        padded = pad(name)
        id = exchange([16, 1, 2 + (padded.bytesize / 4), name.bytesize, 0].pack('CCvvv') + padded)[8, 4].unpack1('V')
        @atoms[name] = id unless id.zero?
        id
      end

      def atom_name(id)
        reply = exchange([17, 0, 2, id].pack('CCvV'))
        reply[32, reply[8, 2].unpack1('v')]
      end

      def property(window, name)
        id = atom(name)
        return nil if id.zero?

        reply = exchange([20, 0, 6, window, id, 0, 0, PROPERTY_WORDS].pack('CCvVVVVV'))
        format = reply.getbyte(1)
        return nil if format.zero?

        raw = reply[32, reply[16, 4].unpack1('V') * format / 8]
        if format == STRING_FORMAT
          raw
        else
          raw.unpack(format == 32 ? 'V*' : 'v*')
        end
      end

      def property_text(window, name)
        value = property(window, name)
        value.is_a?(String) ? String.new(value, encoding: Encoding::UTF_8).scrub : nil
      end

      def property_numbers(window, name)
        value = property(window, name)
        value.is_a?(Array) ? value : []
      end

      def selection_owned?(name)
        id = atom(name)
        !id.zero? && !exchange([23, 0, 2, id].pack('CCvV'))[8, 4].unpack1('V').zero?
      end

      def extension(name)
        return @extensions[name] if @extensions.key?(name)

        padded = pad(name)
        reply = exchange([98, 0, 2 + (padded.bytesize / 4), name.bytesize, 0].pack('CCvvv') + padded)
        present, major_opcode, first_event, first_error = reply[8, 4].unpack('CCCC')
        @extensions[name] = present == 1 ? Extension.new(major_opcode:, first_event:, first_error:) : nil
      end

      def image(drawable, x, y, width, height)
        reply = exchange([73, Z_PIXMAP, 5, drawable, x, y, width, height, ALL_PLANES].pack('CCvVs<s<vvV'),
                         timeout: IMAGE_TIMEOUT)
        Image.new(depth: reply.getbyte(1), visual: reply[8, 4].unpack1('V'), data: reply.byteslice(32..))
      end

      # What GetImage returns for this depth and visual, or nil for a layout cdctl cannot read.
      def pixel_layout(depth, visual_id)
        return nil unless setup.least_significant_byte_first? && setup.bits_per_pixel(depth) == 32

        visual = screen.visuals.find { it.id == visual_id }
        return nil unless visual

        masks = [visual.red_mask, visual.green_mask, visual.blue_mask]
        masks == [0xFF0000, 0x00FF00, 0x0000FF] ? :bgrx : nil
      end
    end
  end
end
