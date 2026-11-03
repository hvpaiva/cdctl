# frozen_string_literal: true

module Cdctl
  module X11
    # What the RandR extension says about the screen. This is the display as X clients see it,
    # which is what the game adopts at launch, even inside a nested compositor.
    module RandR
      Output = Data.define(:name, :x, :y, :width, :height, :refresh_hz) do
        def contains?(point_x, point_y)
          point_x >= x && point_x < x + width && point_y >= y && point_y < y + height
        end

        def to_h = { output: name, width:, height:, refresh_hz:, x:, y: }
      end

      QUERY_VERSION = 0
      GET_OUTPUT_INFO = 9
      GET_CRTC_INFO = 20
      GET_SCREEN_RESOURCES_CURRENT = 25
      MODE_INFO_BYTES = 32

      # nil when the server lacks the extension; an empty list when no output is active.
      def outputs
        randr = extension('RANDR')
        return nil unless randr

        opcode = randr.major_opcode
        exchange([opcode, QUERY_VERSION, 3, 1, 5].pack('CCvVV'))
        reply = exchange([opcode, GET_SCREEN_RESOURCES_CURRENT, 2, screen.root].pack('CCvV'))
        config_time = reply[12, 4].unpack1('V')
        crtc_count, output_count, mode_count = reply[16, 6].unpack('vvv')
        crtcs = reply[32, crtc_count * 4].unpack('V*')
        modes = decode_modes(reply, 32 + ((crtc_count + output_count) * 4), mode_count)
        crtcs.filter_map { read_crtc(opcode, it, config_time, modes) }
      end

      private

      def decode_modes(reply, offset, count)
        (0...count).to_h do |index|
          entry = reply[offset + (index * MODE_INFO_BYTES), MODE_INFO_BYTES]
          [entry[0, 4].unpack1('V'),
           { dot_clock: entry[8, 4].unpack1('V'), h_total: entry[16, 2].unpack1('v'),
             v_total: entry[24, 2].unpack1('v') }]
        end
      end

      def read_crtc(opcode, crtc, config_time, modes)
        reply = exchange([opcode, GET_CRTC_INFO, 3, crtc, config_time].pack('CCvVV'))
        x, y, width, height = reply[12, 8].unpack('s<s<vv')
        mode = reply[20, 4].unpack1('V')
        return nil if mode.zero?

        output_count = reply[28, 2].unpack1('v')
        first_output = reply[32, output_count * 4].to_s.unpack1('V')
        Output.new(name: first_output && output_name(opcode, first_output, config_time), x:, y:, width:, height:,
                   refresh_hz: refresh(modes[mode]))
      end

      def output_name(opcode, output, config_time)
        reply = exchange([opcode, GET_OUTPUT_INFO, 3, output, config_time].pack('CCvVV'))
        crtcs, modes, _preferred, clones, name_length = reply[26, 10].unpack('vvvvv')
        reply[36 + ((crtcs + modes + clones) * 4), name_length]
      end

      def refresh(mode)
        return nil unless mode && mode[:h_total].positive? && mode[:v_total].positive?

        (mode[:dot_clock].to_f / (mode[:h_total] * mode[:v_total])).round(3)
      end
    end
  end
end
