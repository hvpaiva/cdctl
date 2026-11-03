# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'
require 'timeout'

# The same client code against a real X server, so a misreading of the protocol cannot hide in both
# the client and the fake server. CDCTL_REQUIRE_XVFB turns a missing Xvfb into a failure, which CI
# sets, instead of a skip.
class RealXServerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DISPLAY_NUMBER = 91

  # Opens real windows with raw requests, the way any X client does. It never runs in shipped code.
  class WindowMaker
    INPUT_OUTPUT = 1
    BACK_PIXEL = 0x2
    STRING_ATOM = 31
    CARDINAL_ATOM = 6

    def initialize(connection)
      @connection = connection
      @next = 1
    end

    def create(width:, height:, color:, x: 0, y: 0, parent: nil, **properties)
      id = @connection.setup.resource_base | @next
      @next += 1
      send_void([1, 0, 9, id, parent || @connection.screen.root, x, y, width, height, 0, INPUT_OUTPUT, 0, BACK_PIXEL,
                 color].pack('CCvVVs<s<vvvvVVV'))
      properties.each { |name, value| set_property(id, name.to_s, value) }
      send_void([8, 0, 2, id].pack('CCvV'))
      @connection.input_focus
      id
    end

    def set_property(id, name, value)
      type, format, data, count = if value.is_a?(Array)
                                    [CARDINAL_ATOM, 32, value.pack('V*'), value.size]
                                  else
                                    [STRING_ATOM, 8, value.b, value.bytesize]
                                  end
      padded = data + ("\0" * (-data.bytesize % 4))
      send_void([18, 0, 6 + (padded.bytesize / 4), id, intern(name), type, format, 0, 0, 0, count]
                .pack('CCvVVVCCCCV') + padded)
    end

    def resize(id, width, height)
      send_void([12, 0, 5, id, 0x4 | 0x8, 0, width, height].pack('CCvVvvVV'))
      @connection.input_focus
    end

    def focus(id)
      send_void([42, 1, 3, id, 0].pack('CCvVV'))
      @connection.input_focus
    end

    def own_selection(id, name)
      send_void([22, 0, 4, id, intern(name), 0].pack('CCvVVV'))
      @connection.input_focus
    end

    private

    def intern(name)
      padded = name.b + ("\0" * (-name.bytesize % 4))
      @connection.exchange([16, 0, 2 + (padded.bytesize / 4), name.bytesize, 0].pack('CCvvv') + padded)[8,
                                                                                                        4].unpack1('V')
    end

    def send_void(bytes) = @connection.send_request(bytes)
  end

  def setup
    @xvfb = Xvfb.start(DISPLAY_NUMBER)
    unless @xvfb
      raise 'Xvfb is required here' if ENV['CDCTL_REQUIRE_XVFB']

      skip 'Xvfb is not installed'
    end
    @machine = Machine.new
    @machine.env['DISPLAY'] = ":#{DISPLAY_NUMBER}"
    @machine.x11_opener = Cdctl::X11::Connection.method(:open)
    @maker_connection = Cdctl::X11::Connection.open(":#{DISPLAY_NUMBER}")
    @maker = WindowMaker.new(@maker_connection)
  end

  def teardown
    @maker_connection&.close
    @machine&.destroy
    @xvfb&.stop
  end

  def status = @machine.run_json('status')[1][:data]

  def running_game(width: 640, height: 480, color: 0x102030)
    @machine.install_game(@machine.steam_root)
    @machine.run_game
    window = @maker.create(width:, height:, color:, WM_CLASS: "steam_app_#{Machine::APP_ID}\0steam_app\0",
                           WM_NAME: 'Crimson Desert', STEAM_GAME: [Machine::APP_ID],
                           _NET_WM_PID: [4242])
    @maker.focus(window)
    window
  end

  def capture(*)
    _, result, = @machine.run_json('screenshot', *)
    artifact = result[:artifacts].first
    [artifact, PngReader.read(File.binread(artifact[:path])), result]
  end

  def test_connects_and_lists_extensions
    x11 = status[:x11]

    assert_equal 'connected', x11[:status]
    assert x11[:extensions][:XTEST]
    assert x11[:extensions][:RANDR]
    refute x11[:xwayland]
  end

  def test_reads_the_screen_through_randr
    screen = status[:resolution][:game_screen]

    assert_equal 'x11_randr', screen[:source]
    assert_equal [1280, 720], [screen[:value][:width], screen[:value][:height]]
  end

  def test_finds_the_real_window_with_its_evidence
    id = running_game
    window = status[:window]

    assert_equal format('0x%x', id), window[:id]
    assert_equal 'Crimson Desert', window[:title]
    assert_equal [640, 480], [window[:width], window[:height]]
    assert window[:focused]
    assert_equal %w[steam_game_property wm_class net_wm_pid], window[:evidence]
  end

  def test_ignores_a_window_of_another_program
    running_game
    @maker.create(width: 300, height: 300, color: 0, WM_CLASS: "Other\0Other\0")

    assert_equal 'found', status[:window][:state]
  end

  def test_a_region_reads_that_rectangle_of_the_real_window
    window = running_game(width: 200, height: 100, color: 0x336699)
    @maker.create(width: 10, height: 10, x: 20, y: 30, color: 0xFF0000, parent: window)
    artifact, marked, = capture('--region', '20,30,10,10')
    _, plain, = capture('--region', '50,50,10,10')

    assert_equal 'x11_get_image', artifact[:backend]
    assert_equal [10, 10], [marked.width, marked.height]
    assert_equal [0xFF, 0, 0], marked.pixel(5, 5)
    assert_equal [0x33, 0x66, 0x99], plain.pixel(5, 5)
  end

  # X leaves the covered part of a window undefined unless a compositing manager keeps windows
  # apart, and Xvfb has none, so here "only the game" is exactly what a capture must not claim.
  def test_a_capture_says_when_it_cannot_claim_only_the_game
    running_game(width: 200, height: 100)
    _, _, result = capture

    assert_includes result[:not_verified], 'capture.only_the_game'
  end

  def test_a_compositing_manager_is_recognized_by_its_selection
    window = running_game(width: 200, height: 100)

    refute status[:x11][:compositing_manager]
    @maker.own_selection(window, '_NET_WM_CM_S0')

    assert status[:x11][:compositing_manager]
    refute_includes capture.last[:not_verified], 'capture.only_the_game'
  end

  def test_a_real_resize_invalidates_an_observation
    window = running_game
    _, observed, = @machine.run_json('observe')
    @maker.resize(window, 800, 600)
    status, result, = @machine.run_json('observation', 'check', observed[:data][:observation_id])

    assert_equal 3, status
    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_equal(%w[width height], result[:data][:differences].map { it[:field] })
  end

  def test_a_refusal_of_an_earlier_request_is_not_charged_to_the_next_one
    bad_window = 0x7FFFFF

    @maker.set_property(bad_window, 'CDCTL_TEST', 'x')

    assert_kind_of Integer, @maker_connection.input_focus
    assert_equal(1280, @maker_connection.outputs.first.width)
  end
end

# Only commands that do not look at the machine, so this can never reach a real game on the computer
# running it. Every other command runs in-process against a fake machine.
class ExecutableTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def run_program(*)
    Dir.mktmpdir do |home|
      out, status = Open3.capture2({ 'HOME' => home }, RbConfig.ruby, '-I', File.join(ROOT, 'lib'),
                                   File.join(ROOT, 'exe/cdctl'), *)
      [JSON.parse(out), status]
    end
  end

  def test_the_program_answers_with_nothing_set_up
    [%w[version --json], %w[schema status --json], %w[--help --json]].each do |arguments|
      result, status = run_program(*arguments)

      assert_predicate status, :success?, arguments.join(' ')
      assert_equal 'ok', result['status'], arguments.join(' ')
    end
  end
end

class Xvfb
  WAIT_SECONDS = 10

  def self.start(number)
    return nil unless system('sh', '-c', 'command -v Xvfb', out: File::NULL)

    pid = Process.spawn('Xvfb', ":#{number}", '-screen', '0', '1280x720x24', '-nolisten', 'tcp', '-ac',
                        out: File::NULL, err: File::NULL)
    new(pid, number).tap(&:wait_until_ready)
  end

  def initialize(pid, number)
    @pid = pid
    @socket = "/tmp/.X11-unix/X#{number}"
  end

  def wait_until_ready
    Timeout.timeout(WAIT_SECONDS) { sleep(0.05) until File.socket?(@socket) }
  end

  def stop
    Process.kill('TERM', @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
