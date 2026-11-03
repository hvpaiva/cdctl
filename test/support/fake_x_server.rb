# frozen_string_literal: true

require 'socket'
require 'tmpdir'
require 'fileutils'

# Answers the X11 requests cdctl sends, from an in-memory model of windows, over a real socket. The
# byte layouts come from the protocol document, and test/integration checks the same client code
# against a real server, so a misreading of the protocol cannot hide in both places.
class FakeXServer
  ROOT = 0x100
  ROOT_VISUAL = 0x21
  RANDR_OPCODE = 140
  BAD_WINDOW = 3
  BAD_MATCH = 8
  # Every request cdctl may send while it only observes. Nothing here can change the server, and
  # InternAtom is allowed only in its form that never creates a name.
  READ_ONLY_OPCODES = {
    3 => 'GetWindowAttributes', 14 => 'GetGeometry', 15 => 'QueryTree', 16 => 'InternAtom', 17 => 'GetAtomName',
    20 => 'GetProperty', 23 => 'GetSelectionOwner', 40 => 'TranslateCoordinates', 43 => 'GetInputFocus',
    73 => 'GetImage', 98 => 'QueryExtension', RANDR_OPCODE => 'RandR'
  }.freeze
  READ_ONLY_RANDR = [0, 9, 20, 25].freeze
  INTERN_ATOM = 16
  INTERN_ONLY_IF_EXISTS = 1
  GET_IMAGE = 73
  XINPUT_OPCODE = 131
  XTEST_OPCODE = 132
  XTEST_KEYBOARD = 5
  XTEST_POINTER = 4
  REAL_KEYBOARD = 9
  REAL_POINTER = 6
  DEVICES = { 2 => 'Virtual core pointer', 3 => 'Virtual core keyboard', XTEST_POINTER => 'Virtual core XTEST pointer',
              XTEST_KEYBOARD => 'Virtual core XTEST keyboard', REAL_POINTER => 'real-pointer',
              REAL_KEYBOARD => 'real-keyboard' }.freeze
  RAW_TYPES = { key_press: 13, key_release: 14, button_press: 15, button_release: 16, motion: 17 }.freeze
  # What the fake keyboard offers, in keycode order from 8, each with an unused second column.
  KEYSYMS = [0xFF1B, 0xFF0D, 0x20, *('a'..'z').map(&:ord), *('0'..'9').map(&:ord), 0xFFBE].freeze
  FIRST_KEYCODE = 8

  Window = Struct.new(:id, :parent, :x, :y, :width, :height, :depth, :visual, :map_state, :properties, :children,
                      :pixel, keyword_init: true)

  attr_reader :directory, :windows, :extensions, :requests, :keys_down, :buttons_down, :fake_inputs
  attr_accessor :focus, :required_cookie, :silent, :outputs, :after_image, :refuse_images, :truncate_next_reply,
                :late_error, :silent_after, :hang_up_after, :client_timeout, :xi2_version, :pointer, :on_fake_input,
                :refuse_fake_input

  def initialize(display: 7, width: 1920, height: 1080)
    @display = display
    @width = width
    @height = height
    @client_timeout = 1.0
    @directory = Dir.mktmpdir('cdctl-x-')
    @server = UNIXServer.new(File.join(@directory, "X#{display}"))
    @atoms = {}
    @next_atom = 300
    @focus = 1
    @extensions = { 'RANDR' => RANDR_OPCODE, 'XTEST' => XTEST_OPCODE, 'XInputExtension' => XINPUT_OPCODE }
    @selection_owners = {}
    @requests = []
    @outputs = [{ name: 'OUT-1', x: 0, y: 0, width:, height:, dot_clock: 148_500_000, h_total: 2200, v_total: 1125 }]
    @windows = { ROOT => Window.new(id: ROOT, parent: 0, x: 0, y: 0, width:, height:, depth: 24, visual: ROOT_VISUAL,
                                    map_state: 2, properties: {}, children: [], pixel: 0) }
    @keys_down = []
    @buttons_down = []
    @pointer = [0, 0]
    @fake_inputs = []
    @xi2_version = [2, 3]
    @subscribers = []
    @connections = []
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  # A keycode the fake keyboard has for this keysym, as a real server's mapping would say.
  def self.keycode(keysym) = FIRST_KEYCODE + KEYSYMS.index(keysym)

  # What a person pressing something looks like from here: an event from a real device.
  def input_from_a_person(kind = :key_press, device: kind == :motion ? REAL_POINTER : REAL_KEYBOARD)
    deliver(kind, device)
  end

  def fake_input_kinds = fake_inputs.map(&:first)

  def display = ":#{@display}"

  def opener
    directory = @directory
    lambda do |display, cookies: []|
      Cdctl::X11::Connection.open(display, cookies:, socket_directory: directory, timeout: client_timeout)
    end
  end

  def stop
    [@thread, *@connections].each(&:kill)
    @server.close
    FileUtils.remove_entry(@directory)
  end

  def add_window(id, parent: ROOT, x: 0, y: 0, width: 1920, height: 1080, mapped: true, pixel: 0x102030, **props)
    @windows[id] = Window.new(id:, parent:, x:, y:, width:, height:, depth: 24, visual: ROOT_VISUAL,
                              map_state: mapped ? 2 : 0, properties: {}, children: [], pixel:)
    @windows.fetch(parent).children << id
    props.each { |name, value| set_property(id, name.to_s, value) }
    @windows[id]
  end

  def set_property(id, name, value)
    @windows.fetch(id).properties[atom_for(name)] = value
  end

  def client_list(*ids) = set_property(ROOT, '_NET_CLIENT_LIST', ids)

  def atom_for(name)
    @atoms[name] ||= (@next_atom += 1)
  end

  # A compositing manager announces itself by owning this selection.
  def own_compositing_selection(screen = 0)
    @selection_owners[atom_for("_NET_WM_CM_S#{screen}")] = 0x700
  end

  def request_names = requests.map { READ_ONLY_OPCODES.fetch(it[:opcode], "opcode #{it[:opcode]}") }

  def requests_that_could_change_something = requests.reject { read_only?(it) }

  private

  def read_only?(request)
    case request[:opcode]
    when RANDR_OPCODE then READ_ONLY_RANDR.include?(request[:data])
    when INTERN_ATOM then request[:data] == INTERN_ONLY_IF_EXISTS
    else READ_ONLY_OPCODES.key?(request[:opcode])
    end
  end

  # One thread per client: input keeps several connections open at once.
  def serve
    loop do
      client = @server.accept
      @connections << Thread.new(client) { handle(it) }.tap { it.report_on_exception = false }
    end
  rescue IOError, SystemCallError
    nil
  end

  def handle(socket)
    return socket.close unless client_accepted?(socket)

    sequence = 0
    loop do
      head = socket.read(4)
      break if head.nil?

      opcode, data, length = head.unpack('CCv')
      body = length > 1 ? socket.read((length - 1) * 4) : ''.b
      sequence = (sequence + 1) & 0xFFFF
      @requests << { opcode:, data: }
      go_silent_when_due
      break if hang_up_due?
      next if silent

      respond(socket, opcode, data, body, sequence)
    end
    @subscribers.delete(socket)
    socket.close
  rescue IOError, SystemCallError
    @subscribers.delete(socket)
    nil
  end

  def go_silent_when_due
    return unless silent_after

    self.silent_after -= 1
    self.silent = true if silent_after.negative?
  end

  def hang_up_due?
    return false unless hang_up_after

    self.hang_up_after -= 1
    hang_up_after.negative?
  end

  def respond(socket, opcode, data, body, sequence)
    if late_error
      socket.write(error(sequence - 1, late_error, 99))
      self.late_error = nil
    end
    answer = answer(opcode, data, body, sequence, socket)
    return unless answer

    if truncate_next_reply
      socket.write(answer[0, truncate_next_reply])
      self.truncate_next_reply = nil
      self.silent = true
    else
      socket.write(answer)
    end
  end

  def client_accepted?(socket)
    head = socket.read(12)
    _, _, _, _, name_length, data_length = head.unpack('CCvvvv')
    name = socket.read(padded(name_length))[0, name_length]
    cookie = socket.read(padded(data_length))[0, data_length]
    if required_cookie && (name != 'MIT-MAGIC-COOKIE-1' || cookie != required_cookie)
      reason = 'Invalid MIT-MAGIC-COOKIE-1 key'
      socket.write([0, reason.bytesize, 11, 0, padded(reason.bytesize) / 4].pack('CCvvv') + pad(reason))
      return false
    end
    socket.write(setup_reply)
    true
  end

  def setup_reply
    vendor = 'fake'
    body = [0, 0x400000, 0x1FFFFF, 256, vendor.bytesize, 65_535, 1, 1, 0, 0, 32, 32, 8, 255, 0]
           .pack('VVVVvvCCCCCCCCV') + pad(vendor)
    body << [24, 32, 32].pack('CCC') << ("\0" * 5)
    body << [ROOT, 0x20, 0xFFFFFF, 0, 0, @width, @height, 508, 285, 1, 1, ROOT_VISUAL, 0, 0, 24, 1]
            .pack('VVVVVvvvvvvVCCCC')
    body << [24, 0, 1, 0].pack('CCvV')
    body << [ROOT_VISUAL, 4, 8, 256, 0xFF0000, 0x00FF00, 0x0000FF, 0].pack('VCCvVVVV')
    [1, 0, 11, 0, body.bytesize / 4].pack('CCvvv') + body
  end

  def answer(opcode, data, body, sequence, socket)
    case opcode
    when 3 then with_window(body, opcode, sequence) { attributes_reply(it, sequence) }
    when 14 then with_window(body, opcode, sequence) { geometry_reply(it, sequence) }
    when 15 then with_window(body, opcode, sequence) { tree_reply(it, sequence) }
    when INTERN_ATOM then intern_atom_reply(body, sequence)
    when 17 then atom_name_reply(body, sequence)
    when 20 then with_window(body, opcode, sequence) { property_reply(it, body, sequence) }
    when 23 then selection_owner_reply(body, sequence)
    when 38 then pointer_reply(sequence)
    when 40 then with_window(body, opcode, sequence) { translate_reply(it, sequence) }
    when 43 then reply(sequence, 1, [@focus].pack('V'))
    when 44 then keymap_reply(sequence)
    when GET_IMAGE then image_reply(body, opcode, sequence)
    when 98 then extension_reply(body, sequence)
    when 101 then keyboard_mapping_reply(body, sequence)
    when RANDR_OPCODE then randr_reply(data, body, sequence)
    when XTEST_OPCODE then xtest_answer(data, body, sequence)
    when XINPUT_OPCODE then xinput_answer(data, sequence, socket)
    else error(sequence, 1, opcode)
    end
  end

  def pointer_reply(sequence)
    mask = @buttons_down.sum { 1 << (8 + it - 1) }
    reply(sequence, 1, [ROOT, 0, *@pointer, *@pointer, mask].pack('VVs<s<s<s<v'))
  end

  def keymap_reply(sequence)
    bytes = Array.new(32, 0)
    @keys_down.each { bytes[it / 8] |= 1 << (it % 8) }
    [1, 0, sequence, 2].pack('CCvV') + bytes.pack('C*')
  end

  def keyboard_mapping_reply(body, sequence)
    first, count = body.unpack('CC')
    syms = (0...count).flat_map { [KEYSYMS.fetch(first + it - FIRST_KEYCODE, 0), 0] }
    reply(sequence, 2, '', syms.pack('V*'))
  end

  def xtest_answer(minor, body, sequence)
    return reply(sequence, 2, [2].pack('v')) if minor.zero?
    return error(sequence, 1, XTEST_OPCODE) unless minor == 2
    return error(sequence, 2, XTEST_OPCODE) if refuse_fake_input

    type, detail = body.unpack('CC')
    apply_fake_input(type, detail, *body[20, 4].unpack('s<s<'))
    nil
  end

  def apply_fake_input(type, detail, x, y)
    case type
    when 2 then press(@keys_down, detail, :key_press, XTEST_KEYBOARD)
    when 3 then release(@keys_down, detail, :key_release, XTEST_KEYBOARD)
    when 4 then press(@buttons_down, detail, :button_press, XTEST_POINTER)
    when 5 then release(@buttons_down, detail, :button_release, XTEST_POINTER)
    when 6
      @pointer = [x, y]
      deliver(:motion, XTEST_POINTER)
    end
    @fake_inputs << [type, detail, x, y]
    on_fake_input&.call(type, detail)
  end

  def press(down, detail, kind, device)
    down << detail unless down.include?(detail)
    deliver(kind, device)
  end

  def release(down, detail, kind, device)
    down.delete(detail)
    deliver(kind, device)
  end

  def xinput_answer(minor, sequence, socket)
    case minor
    when 47 then reply(sequence, 0, xi2_version.pack('vv'))
    when 48 then xi_devices_reply(sequence)
    when 46
      @subscribers << socket
      nil
    else error(sequence, 1, XINPUT_OPCODE)
    end
  end

  def xi_devices_reply(sequence)
    empty_class = [0, 2, 0, 0].pack('vvvv')
    entries = DEVICES.map do |id, name|
      use = name.include?('pointer') ? 3 : 4
      [id, use, 2, 1, name.bytesize, 1, 0].pack('vvvvvCC') + pad(name) + empty_class
    end
    reply(sequence, 0, [DEVICES.size].pack('v'), entries.join)
  end

  def deliver(kind, device)
    event = [35, XINPUT_OPCODE, 0, 0, RAW_TYPES.fetch(kind), 3, 0, 0, device, 0, 0, 0].pack('CCvVvvVVvvVV')
    @subscribers.each do |socket|
      socket.write(event)
    rescue IOError, SystemCallError
      nil
    end
  end

  def with_window(body, opcode, sequence)
    window = @windows[body[0, 4].unpack1('V')]
    window ? yield(window) : error(sequence, BAD_WINDOW, opcode)
  end

  def reply(sequence, first, fixed, extra = ''.b)
    fixed = fixed.ljust(24, "\0")
    extra = pad(extra)
    [1, first, sequence, (fixed.bytesize + extra.bytesize - 24) / 4].pack('CCvV') + fixed + extra
  end

  def error(sequence, code, major)
    [0, code, sequence & 0xFFFF, 0, 0, major].pack('CCvVvC').ljust(32, "\0")
  end

  def attributes_reply(window, sequence)
    fixed = [window.visual, 1, 0, 0, 0, 0, 0, 0, window.map_state, 0, 0, 0, 0, 0].pack('VvCCVVCCCCVVVv').ljust(36, "\0")
    reply(sequence, 0, fixed)
  end

  def geometry_reply(window, sequence)
    reply(sequence, window.depth, [ROOT, window.x, window.y, window.width, window.height, 0].pack('Vs<s<vvv'))
  end

  def tree_reply(window, sequence)
    reply(sequence, 0, [ROOT, window.parent, window.children.size].pack('VVv'), window.children.pack('V*'))
  end

  def intern_atom_reply(body, sequence)
    length = body[0, 2].unpack1('v')
    reply(sequence, 0, [@atoms.fetch(body[4, length], 0)].pack('V'))
  end

  def atom_name_reply(body, sequence)
    name = @atoms.key(body[0, 4].unpack1('V')).to_s
    reply(sequence, 0, [name.bytesize].pack('v'), name.b)
  end

  def property_reply(window, body, sequence)
    value = window.properties[body[4, 4].unpack1('V')]
    return reply(sequence, 0, ''.b) if value.nil?

    format, count, raw = value.is_a?(Array) ? [32, value.size, value.pack('V*')] : [8, value.bytesize, value.b]
    reply(sequence, format, [0, 0, count].pack('VVV'), raw)
  end

  def selection_owner_reply(body, sequence)
    reply(sequence, 0, [@selection_owners.fetch(body[0, 4].unpack1('V'), 0)].pack('V'))
  end

  def translate_reply(window, sequence)
    reply(sequence, 1, [0, window.x, window.y].pack('Vs<s<'))
  end

  def image_reply(body, opcode, sequence)
    id, x, y, width, height = body.unpack('Vs<s<vv')
    window = @windows[id]
    return error(sequence, BAD_WINDOW, opcode) unless window
    return error(sequence, BAD_MATCH, opcode) if refuse_images || window.map_state != 2

    pixels = pixels_of(window, x, y, width, height)
    after_image&.call(window)
    reply(sequence, window.depth, [window.visual].pack('V'), pixels)
  end

  # A window's pixel can be a callable of window coordinates, which proves a capture reads the
  # rectangle it asked for and not some other one of the same size.
  def pixels_of(window, left, top, width, height)
    return slice_of(window, left, top, width, height) if window.pixel.is_a?(String)
    return [window.pixel].pack('V') * (width * height) unless window.pixel.respond_to?(:call)

    (top...(top + height)).flat_map { |y| (left...(left + width)).map { |x| window.pixel.call(x, y) } }.pack('V*')
  end

  # A window can hold a whole frame already packed, which a test draws once.
  def slice_of(window, left, top, width, height)
    stride = window.width * 4
    (top...(top + height)).map { window.pixel.byteslice((it * stride) + (left * 4), width * 4) }.join
  end

  def extension_reply(body, sequence)
    length = body[0, 2].unpack1('v')
    opcode = @extensions[body[4, length]]
    reply(sequence, 0, [opcode ? 1 : 0, opcode.to_i, 0, 0].pack('CCCC'))
  end

  def randr_reply(minor, body, sequence)
    case minor
    when 0 then reply(sequence, 0, [1, 5].pack('VV'))
    when 25 then screen_resources_reply(sequence)
    when 20 then crtc_reply(body, sequence)
    when 9 then output_reply(body, sequence)
    else error(sequence, 1, RANDR_OPCODE)
    end
  end

  def screen_resources_reply(sequence)
    count = outputs.size
    crtcs = (1..count).map { 0x500 + it }.pack('V*')
    output_ids = (1..count).map { 0x600 + it }.pack('V*')
    modes = outputs.each_with_index.map do |output, index|
      [0x700 + index, output[:width], output[:height], output[:dot_clock], 0, 0, output[:h_total], 0, 0, 0,
       output[:v_total], 0, 0].pack('VvvVvvvvvvvvV')
    end.join
    reply(sequence, 0, [0, 77, count, count, count, 0].pack('VVvvvv'), crtcs + output_ids + modes)
  end

  def crtc_reply(body, sequence)
    index = body[0, 4].unpack1('V') - 0x501
    output = outputs.fetch(index)
    reply(sequence, 0, [0, output[:x], output[:y], output[:width], output[:height], 0x700 + index, 1, 1, 1, 0]
                       .pack('Vs<s<vvVvvvv'), [0x601 + index].pack('V'))
  end

  def output_reply(body, sequence)
    name = outputs.fetch(body[0, 4].unpack1('V') - 0x601)[:name]
    reply(sequence, 0, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, name.bytesize].pack('VVVVCCvvvvv').ljust(28, "\0"), name.b)
  end

  def padded(length) = (length + 3) & ~3

  def pad(text) = text.b + ("\0" * (-text.bytesize % 4))
end
