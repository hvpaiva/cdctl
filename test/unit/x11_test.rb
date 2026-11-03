# frozen_string_literal: true

require 'test_helper'
require 'cdctl/game'
require 'cdctl/game_window'
require 'cdctl/x11/authority'

class DisplayTest < Minitest::Test
  def parse(text) = Cdctl::X11::Display.parse(text)

  def test_reads_local_forms
    assert_equal 0, parse(':0').number
    assert_equal 3, parse('unix:3.1').number
    assert_equal 1, parse(':2.1').screen
  end

  def test_refuses_a_remote_display
    assert_raises(Cdctl::X11::ConnectError) { parse('example.com:0') }
    assert_raises(Cdctl::X11::ConnectError) { parse(nil) }
  end
end

class AuthorityTest < Minitest::Test
  def entry(number, data, name: 'MIT-MAGIC-COOKIE-1')
    fields = ['host', number, name, data].map { [it.bytesize].pack('n') + it }
    [256].pack('n') + fields.join
  end

  def with_file(bytes)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'xauth')
      File.binwrite(path, bytes)
      yield path
    end
  end

  def test_picks_the_cookie_of_the_display
    with_file(entry('0', 'zero') + entry('1', 'one')) do |path|
      assert_equal ['one'], Cdctl::X11::Authority.cookies(1, [path])
    end
  end

  def test_an_entry_without_a_number_serves_every_display
    with_file(entry('', 'any')) { |path| assert_equal ['any'], Cdctl::X11::Authority.cookies(9, [path]) }
  end

  def test_ignores_other_schemes_and_broken_files
    with_file(entry('0', 'x', name: 'XDM-AUTHORIZATION-1')) do |path|
      assert_empty Cdctl::X11::Authority.cookies(0, [path])
    end
    with_file("\x01\x00\xFF".b) { |path| assert_empty Cdctl::X11::Authority.cookies(0, [path]) }
    assert_empty Cdctl::X11::Authority.cookies(0, ['/nonexistent'])
  end
end

class ConnectionTest < Minitest::Test
  def setup
    @server = FakeXServer.new
  end

  def teardown = @server.stop

  def connect(cookies: [])
    connection = Cdctl::X11::Connection.open(@server.display, cookies:, socket_directory: @server.directory,
                                                              timeout: 0.3)
    yield connection
  ensure
    connection&.close
  end

  def test_reads_the_screen_from_the_setup
    connect do |x|
      assert_equal FakeXServer::ROOT, x.screen.root
      assert_equal 1920, x.screen.width
      assert_equal 1080, x.screen.height
    end
  end

  def test_tries_each_cookie_until_one_is_accepted
    @server.required_cookie = 'right'

    connect(cookies: %w[wrong right]) { |x| assert_equal 1920, x.screen.width }
  end

  def test_a_refusal_says_why_and_holds_no_cookie
    @server.required_cookie = 'right'
    error = assert_raises(Cdctl::X11::ConnectError) { connect(cookies: ['s3cret']) { nil } }

    assert_match(/Invalid MIT-MAGIC-COOKIE-1/, error.message)
    refute_includes error.message, 's3cret'
  end

  def test_a_missing_server_is_a_connect_error
    error = assert_raises(Cdctl::X11::ConnectError) do
      Cdctl::X11::Connection.open(':99', socket_directory: @server.directory)
    end

    assert_match(/cannot reach X server 99/, error.message)
  end

  def test_a_silent_server_times_out_instead_of_hanging
    connect do |x|
      @server.silent = true
      assert_raises(Cdctl::X11::TimeoutError) { x.input_focus }
    end
  end

  # The rest of that reply would otherwise be read as the answer to the next request.
  def test_a_connection_that_timed_out_is_never_read_again
    connect do |x|
      @server.truncate_next_reply = 10
      assert_raises(Cdctl::X11::TimeoutError) { x.input_focus }
      @server.silent = false
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(Cdctl::X11::TimeoutError) { x.input_focus }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.2
    end
  end

  def test_a_late_refusal_is_not_charged_to_the_next_request
    connect do |x|
      @server.late_error = Cdctl::X11::RequestError::BAD_WINDOW

      assert_equal 1, x.input_focus
    end
  end

  def test_a_server_that_never_finishes_the_handshake_is_a_timeout
    Dir.mktmpdir do |directory|
      listener = UNIXServer.new(File.join(directory, 'X5'))

      assert_raises(Cdctl::X11::TimeoutError) do
        Cdctl::X11::Connection.open(':5', socket_directory: directory, timeout: 0.05)
      end
    ensure
      listener&.close
    end
  end

  def test_a_socket_of_another_user_gets_no_credential
    peer = Struct.new(:getpeereid)
    error = assert_raises(Cdctl::X11::ConnectError) do
      Cdctl::X11::Connection.verify_peer(peer.new([1234, 1234]), 5, own_uid: 1000)
    end

    assert_match(/another user/, error.message)
    assert_nil Cdctl::X11::Connection.verify_peer(peer.new([1000, 1000]), 5, own_uid: 1000)
    assert_nil Cdctl::X11::Connection.verify_peer(peer.new([0, 0]), 5, own_uid: 1000)
  end

  def test_reads_whether_a_selection_has_an_owner
    connect do |x|
      refute x.selection_owned?('_NET_WM_CM_S0')
      @server.own_compositing_selection

      assert x.selection_owned?('_NET_WM_CM_S0')
    end
  end

  def test_an_x_error_names_the_problem
    connect do |x|
      error = assert_raises(Cdctl::X11::RequestError) { x.geometry(0xDEAD) }

      assert_equal Cdctl::X11::RequestError::BAD_WINDOW, error.error_code
      assert_match(/BadWindow/, error.message)
    end
  end

  def test_reads_text_and_number_properties
    @server.add_window(0x10, WM_NAME: 'Title', _NET_WM_PID: [42])
    connect do |x|
      assert_equal 'Title', x.property_text(0x10, 'WM_NAME')
      assert_equal [42], x.property_numbers(0x10, '_NET_WM_PID')
      assert_nil x.property(0x10, 'NEVER_INTERNED')
    end
  end

  def test_reads_outputs_through_randr
    @server.outputs = [{ name: 'LEFT', x: 0, y: 0, width: 2000, height: 1000, dot_clock: 120_000_000, h_total: 2000,
                         v_total: 1000 },
                       { name: 'RIGHT', x: 2000, y: 0, width: 1000, height: 1000, dot_clock: 60_000_000, h_total: 1000,
                         v_total: 1000 }]
    connect do |x|
      left, right = x.outputs

      assert_equal 'LEFT', left.name
      assert_in_delta 60.0, left.refresh_hz
      assert_equal 'RIGHT', right.name
      assert_equal 2000, right.x
    end
  end

  def test_recognizes_the_usual_pixel_layout_only
    connect do |x|
      assert_equal :bgrx, x.pixel_layout(24, FakeXServer::ROOT_VISUAL)
      assert_nil x.pixel_layout(24, 0x999)
      assert_nil x.pixel_layout(16, FakeXServer::ROOT_VISUAL)
    end
  end
end

class WindowFinderTest < Minitest::Test
  APP_ID = Cdctl::Game::APP_ID

  def setup
    @server = FakeXServer.new
    @connection = @server.opener.call(@server.display)
  end

  def teardown
    @connection.close
    @server.stop
  end

  def find(pid: 42)
    Cdctl::WindowFinder.new(@connection, app_id: APP_ID, window_class: Cdctl::Game::WINDOW_CLASS,
                                         pid:).candidates
  end

  def test_each_property_alone_identifies_the_window
    { STEAM_GAME: [APP_ID], WM_CLASS: "#{Cdctl::Game::WINDOW_CLASS}\0x\0",
      _NET_WM_PID: [42] }.each do |name, value|
      id = 0x10 + (value.hash.abs % 1000)
      @server.add_window(id, name => value)
      @server.client_list(id)

      assert_equal [id], find.map(&:id), name.to_s
    end
  end

  def test_other_windows_are_not_the_game
    @server.add_window(0x10, WM_CLASS: "steam\0Steam\0", _NET_WM_PID: [1])
    @server.client_list(0x10)

    assert_empty find
  end

  def test_an_unmapped_or_tiny_window_is_not_a_target
    @server.add_window(0x10, STEAM_GAME: [APP_ID], mapped: false)
    @server.add_window(0x11, STEAM_GAME: [APP_ID], width: 1, height: 1)
    @server.client_list(0x10, 0x11)

    assert_empty find
  end

  def test_two_real_windows_stay_two
    @server.add_window(0x10, STEAM_GAME: [APP_ID])
    @server.add_window(0x11, STEAM_GAME: [APP_ID])
    @server.client_list(0x10, 0x11)

    assert_equal 2, find.size
  end

  def test_without_a_window_manager_the_tree_is_searched
    frame = 0x20
    @server.add_window(frame)
    @server.add_window(0x21, parent: frame, STEAM_GAME: [APP_ID])

    assert_equal [0x21], find.map(&:id)
  end

  def test_focus_on_a_child_counts_as_focus
    @server.add_window(0x10, STEAM_GAME: [APP_ID])
    @server.add_window(0x30, parent: 0x10)
    @server.client_list(0x10)
    @server.focus = 0x30

    assert_predicate find.first, :focused
  end

  def test_pointer_root_focus_is_not_focus
    @server.add_window(0x10, STEAM_GAME: [APP_ID])
    @server.client_list(0x10)
    @server.focus = Cdctl::X11::Requests::POINTER_ROOT_FOCUS

    refute_predicate find.first, :focused
  end

  def test_keeps_the_child_window_size_as_evidence
    @server.add_window(0x10, STEAM_GAME: [APP_ID], width: 3440, height: 1440)
    @server.add_window(0x30, parent: 0x10, width: 2560, height: 1440)
    @server.client_list(0x10)

    assert_equal 2560, find.first.children.first[:width]
  end

  def test_a_window_gone_mid_scan_is_skipped
    @server.add_window(0x10, STEAM_GAME: [APP_ID])
    @server.client_list(0xDEAD, 0x10)

    assert_equal [0x10], find.map(&:id)
  end

  def test_a_child_that_vanishes_does_not_lose_the_game
    @server.add_window(0x10, STEAM_GAME: [APP_ID]).children << 0xDEAD
    @server.client_list(0x10)

    assert_equal [0x10], find.map(&:id)
    assert_empty find.first.children
  end

  def test_a_focus_owner_that_vanishes_does_not_lose_the_game
    @server.add_window(0x10, STEAM_GAME: [APP_ID])
    @server.client_list(0x10)
    @server.focus = 0xDEAD

    assert_equal [false], find.map(&:focused)
  end
end
