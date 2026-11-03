# frozen_string_literal: true

require 'test_helper'

class FrameTest < Minitest::Test
  # Two rows of two BGRX pixels: blue, green / red, white.
  PIXELS = [255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 255, 255, 255, 0].pack('C*')

  def frame = Cdctl::Capture::Frame.new(width: 2, height: 2, layout: :bgrx, pixels: PIXELS)

  def test_writes_true_colors
    image = PngReader.read(Cdctl::Capture::Png.encode(frame))

    assert_equal [0, 0, 255], image.pixel(0, 0)
    assert_equal [0, 255, 0], image.pixel(1, 0)
    assert_equal [255, 0, 0], image.pixel(0, 1)
    assert_equal [255, 255, 255], image.pixel(1, 1)
  end

  def test_a_crop_keeps_the_exact_pixels
    image = PngReader.read(Cdctl::Capture::Png.encode(frame.crop(1, 1, 1, 1)))

    assert_equal 1, image.width
    assert_equal [255, 255, 255], image.pixel(0, 0)
  end

  def test_zoom_repeats_pixels_and_invents_nothing
    image = PngReader.read(Cdctl::Capture::Png.encode(frame, zoom: 3))

    assert_equal [6, 6], [image.width, image.height]
    assert_equal [[0, 0, 255]], [image.pixel(0, 0), image.pixel(2, 2)].uniq
    assert_equal [[255, 255, 255]], [image.pixel(3, 3), image.pixel(5, 5)].uniq
  end

  def test_blank_means_only_black
    black = Cdctl::Capture::Frame.new(width: 2, height: 1, layout: :rgb, pixels: "\0".b * 6)

    assert_predicate black, :blank?
    refute_predicate frame, :blank?
  end

  def test_reads_grim_output
    parsed = Cdctl::Capture::Ppm.parse("P6\n# made by a test\n2 1\n255\n".b + "\x01\x02\x03\x04\x05\x06".b)

    assert_equal [2, 1, :rgb], [parsed.width, parsed.height, parsed.layout]
  end

  def test_refuses_bad_ppm
    ['P5 1 1 255 x', "P6\n2 2\n255\nabc", "P6\n1 1\n65535\nabcabc"].each do |bytes|
      assert_raises(Cdctl::Capture::Ppm::ParseError) { Cdctl::Capture::Ppm.parse(bytes.b) }
    end
  end
end

class ScreenshotCommandTest < Minitest::Test
  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def shoot(*)
    @machine.run_json('screenshot', *)
  end

  def test_reports_the_real_pixels_the_region_and_the_hash
    @machine.full_game(width: 800, height: 600)
    status, result, = shoot('--region', '10,20,300,200')
    artifact = result[:artifacts].first

    assert_equal 0, status
    assert_equal [300, 200], [artifact[:width], artifact[:height]]
    assert_equal({ space: 'window', x: 10, y: 20, width: 300, height: 200 }, artifact[:region])
    assert_equal 4242, artifact[:pid]
    assert_equal Digest::SHA256.file(artifact[:path]).hexdigest, artifact[:sha256]
    assert_equal([300, 200], PngReader.read(File.binread(artifact[:path])).then { [it.width, it.height] })
  end

  def test_the_region_is_relative_to_the_window_and_reported_on_screen_too
    @machine.start_x(width: 1000, height: 800)
    @machine.install_game(@machine.steam_root)
    @machine.run_game
    @machine.game_window(width: 400, height: 300, x: 100, y: 50)
    _, result, = shoot('--region', '10,10,20,20')

    assert_equal({ x: 110, y: 60, width: 20, height: 20 }, result[:artifacts].first[:absolute_region])
  end

  def test_captures_the_window_pixels_and_never_calls_a_screen_grabber
    @machine.full_game(width: 100, height: 100)
    _, result, = shoot

    assert_equal 'x11_get_image', result[:artifacts].first[:backend]
    assert_empty(@machine.shell.calls.select { it.first == 'grim' })
    assert_equal [0x10, 0x20, 0x30], PngReader.read(File.binread(result[:artifacts].first[:path])).pixel(0, 0)
  end

  def test_reads_the_rectangle_it_asked_for
    @machine.full_game(width: 100, height: 100)
    @machine.x_server.windows.fetch(Machine::GAME_WINDOW).pixel = ->(x, y) { x == 20 && y == 30 ? 0xFF0000 : 0x102030 }
    _, result, = shoot('--region', '20,30,2,2')
    image = PngReader.read(File.binread(result[:artifacts].first[:path]))

    assert_equal [0xFF, 0, 0], image.pixel(0, 0)
    assert_equal [0x10, 0x20, 0x30], image.pixel(1, 1)
  end

  def test_a_capture_says_what_it_cannot_claim_without_a_compositing_manager
    @machine.full_game(width: 100, height: 100)
    _, result, = shoot

    assert_includes result[:not_verified], 'capture.only_the_game'
    assert_includes result[:not_verified], 'system_dialogs'
    assert_equal 'unavailable', result[:data][:modals][:status]
  end

  def test_a_compositing_manager_keeps_the_pixels_of_each_window_apart
    @machine.full_game(width: 100, height: 100)
    @machine.x_server.own_compositing_selection
    _, result, = shoot

    refute_includes result[:not_verified], 'capture.only_the_game'
  end

  def test_a_black_frame_is_not_called_proof_of_anything
    @machine.full_game(width: 100, height: 100)
    @machine.x_server.windows.fetch(Machine::GAME_WINDOW).pixel = 0
    _, result, = shoot

    assert_includes result[:not_verified], 'capture.frame_is_not_blank'
  end

  def test_a_move_during_the_capture_discards_the_frame
    @machine.full_game(width: 100, height: 100)
    @machine.x_server.after_image = ->(window) { window.x = 5 }
    status, result, = shoot

    assert_equal 3, status
    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_empty Dir.glob(File.join(@machine.home, '.local/state/cdctl/evidence/*'))
  end

  def test_a_server_that_stops_answering_during_the_capture_is_a_timeout
    @machine.full_game(width: 100, height: 100)
    server = @machine.x_server
    server.client_timeout = 0.05
    server.after_image = ->(_window) { server.silent = true }
    status, result, = shoot

    assert_equal 1, status
    assert_equal 'TIMEOUT', result[:error][:code]
    assert_empty Dir.glob(File.join(@machine.home, '.local/state/cdctl/evidence/*'))
  end

  def test_files_are_private_and_hold_no_pixels_in_the_result
    @machine.full_game(width: 100, height: 100)
    _, out, = @machine.run('screenshot', '--json')
    path = JSON.parse(out).dig('artifacts', 0, 'path')

    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_operator out.bytesize, :<, 4096
  end

  def test_an_output_path_replaces_a_planted_link_instead_of_following_it
    @machine.full_game(width: 100, height: 100)
    victim = File.join(@machine.home, 'victim')
    File.write(victim, 'untouched')
    planted = File.join(@machine.home, 'shot.png')
    File.symlink(victim, planted)
    shoot('--output', planted)

    assert_equal 'untouched', File.read(victim)
    refute File.symlink?(planted)
  end

  def test_a_region_outside_the_window_is_refused
    @machine.full_game(width: 100, height: 100)
    status, result, = shoot('--region', '90,90,20,20')

    assert_equal 3, status
    assert_equal 'PRECONDITION_FAILED', result[:error][:code]
  end

  def test_bad_arguments_are_usage_errors
    @machine.full_game(width: 100, height: 100)

    assert_equal 2, shoot('--region', 'hud.left')[0]
    assert_equal 2, shoot('--zoom', 'big')[0]
    assert_equal 2, shoot('--backend', 'magic')[0]
  end

  def test_a_large_zoom_is_refused
    @machine.full_game(width: 1000, height: 1000)
    _, result, = shoot('--zoom', '8')

    assert_equal 'PRECONDITION_FAILED', result[:error][:code]
  end

  def test_a_closed_game_has_nothing_to_capture
    @machine.start_x
    @machine.install_game(@machine.steam_root)
    status, result, = shoot

    assert_equal 3, status
    assert_equal 'GAME_NOT_RUNNING', result[:error][:code]
    assert_equal 'not_running', result[:data][:game][:state]
  end

  def test_a_resize_during_the_capture_discards_the_frame
    @machine.full_game(width: 100, height: 100)
    @machine.x_server.after_image = ->(window) { window.width = 200 }
    status, result, = shoot
    evidence = Dir.glob(File.join(@machine.home, '.local/state/cdctl/evidence/*'))

    assert_equal 3, status
    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_empty evidence
  end

  def test_two_windows_are_refused
    @machine.full_game(width: 100, height: 100)
    @machine.x_server.add_window(0x77, STEAM_GAME: [Machine::APP_ID], width: 100, height: 100)
    @machine.x_server.client_list(Machine::GAME_WINDOW, 0x77)
    status, result, = shoot

    assert_equal 3, status
    assert_equal 'TARGET_AMBIGUOUS', result[:error][:code]
  end

  def test_a_game_without_an_x_window_says_why
    @machine.install_game(@machine.steam_root)
    @machine.run_game
    status, result, = shoot

    assert_equal 3, status
    assert_equal 'WINDOW_NOT_FOUND', result[:error][:code]
    assert_match(/X11 is not reachable/, result[:error][:message])
  end

  def test_not_focused_means_the_frame_may_be_old
    @machine.full_game(width: 100, height: 100)
    @machine.x_server.focus = 1
    _, result, = shoot

    assert_includes result[:not_verified], 'capture.frame_is_current'
  end

  def test_old_evidence_is_pruned_and_a_named_file_is_not
    @machine.full_game(width: 100, height: 100)
    File.write(File.join(@machine.home, 'config.yaml'), "evidence_keep: 2\n")
    @machine.env['CDCTL_CONFIG'] = File.join(@machine.home, 'config.yaml')
    mine = File.join(@machine.home, 'mine.png')
    shoot('--output', mine)
    3.times do |index|
      shoot
      Dir.glob(File.join(@machine.home, '.local/state/cdctl/evidence/*.png')).each { File.utime(index, index, it) }
    end

    assert_equal 2, Dir.glob(File.join(@machine.home, '.local/state/cdctl/evidence/*.png')).size
    assert_path_exists mine
  end
end

class GrimFallbackTest < Minitest::Test
  SIZE = { width: 100, height: 100 }.freeze
  PPM = "P6\n100 100\n255\n".b + ("\x10\x20\x30".b * 10_000)

  def setup
    @machine = Machine.new
    @machine.full_game(**SIZE)
  end

  def teardown = @machine.destroy

  def shoot(*) = @machine.run_json('screenshot', *)

  def test_grim_runs_when_the_game_is_on_top
    @machine.hyprland(**SIZE)
    @machine.shell.on('grim', stdout: PPM)
    _, result, = shoot('--backend', 'grim')

    assert_equal 'grim', result[:artifacts].first[:backend]
  end

  def test_grim_is_refused_when_another_window_is_on_top
    @machine.hyprland(active_pid: 1, **SIZE)
    @machine.shell.on('grim', stdout: PPM)
    status, result, = shoot('--backend', 'grim')

    assert_equal 4, status
    assert_equal 'UNSUPPORTED_BACKEND', result[:error][:code]
    assert_empty(@machine.shell.calls.select { it.first == 'grim' })
  end

  def test_grim_is_refused_without_a_compositor_to_prove_it
    @machine.shell.on('grim', stdout: PPM)
    status, = shoot('--backend', 'grim')

    assert_equal 4, status
  end

  def test_a_black_x11_frame_falls_back_and_says_why
    @machine.x_server.windows.fetch(Machine::GAME_WINDOW).pixel = 0
    @machine.hyprland(**SIZE)
    @machine.shell.on('grim', stdout: PPM)
    _, result, = shoot
    artifact = result[:artifacts].first

    assert_equal 'grim', artifact[:backend]
    assert_match(/black/, artifact[:fallback_reason])
  end

  def test_a_black_frame_stands_when_nothing_shows_otherwise
    @machine.x_server.windows.fetch(Machine::GAME_WINDOW).pixel = 0
    _, result, = shoot

    assert_equal 'x11_get_image', result[:artifacts].first[:backend]
    assert result[:artifacts].first[:blank_suspected]
  end

  def evidence = Dir.glob(File.join(@machine.home, '.local/state/cdctl/evidence/*'))

  def surface(namespace, x: 0, y: 0, width: 50, height: 50)
    { 'namespace' => namespace, 'x' => x, 'y' => y, 'w' => width, 'h' => height }
  end

  def assert_grim_refused(pattern)
    status, result, = shoot('--backend', 'grim')

    assert_equal 4, status
    assert_equal 'UNSUPPORTED_BACKEND', result[:error][:code]
    assert_match pattern, result[:error][:message]
    assert_empty evidence
  end

  def test_focus_moving_during_grim_discards_the_frame
    @machine.hyprland(**SIZE)
    @machine.shell.on('grim') do
      @machine.hyprland(active_pid: 99, **SIZE)
      PPM
    end

    assert_grim_refused(/other surfaces/)
  end

  def test_a_dialog_appearing_during_grim_discards_the_frame
    @machine.hyprland(**SIZE)
    @machine.shell.on('grim') do
      @machine.hyprland(layers: { '3' => [surface('some-auth-agent')] }, **SIZE)
      PPM
    end

    assert_grim_refused(/some-auth-agent/)
  end

  def test_the_window_moving_during_grim_discards_the_frame
    @machine.hyprland(**SIZE)
    @machine.shell.on('grim') do
      @machine.hyprland(x: 30, **SIZE)
      PPM
    end

    assert_grim_refused(/place the game differently/)
  end

  def test_the_compositor_is_asked_again_on_both_sides_of_the_capture
    @machine.hyprland(**SIZE)
    @machine.shell.on('grim', stdout: PPM)
    shoot('--backend', 'grim')

    assert_equal(3, @machine.shell.calls.count { it.last == 'activewindow' })
  end

  def test_grim_is_refused_when_the_compositor_places_the_game_elsewhere
    @machine.hyprland(x: 10, **SIZE)
    @machine.shell.on('grim', stdout: PPM)

    assert_grim_refused(/place the game differently/)
    assert_empty(@machine.shell.calls.select { it.first == 'grim' })
  end

  def test_a_notification_over_the_capture_keeps_grim_out
    @machine.hyprland(layers: { '3' => [surface('mako')] }, **SIZE)
    @machine.shell.on('grim', stdout: PPM)

    assert_grim_refused(/mako/)
  end

  def test_a_notification_outside_the_capture_does_not
    @machine.hyprland(layers: { '3' => [surface('mako')] }, **SIZE)
    @machine.shell.on('grim', stdout: PPM)
    _, result, = shoot('--backend', 'grim', '--region', '60,60,10,10')

    assert_equal 'grim', result[:artifacts].first[:backend]
  end

  def test_a_top_layer_surface_over_a_window_keeps_grim_out
    @machine.hyprland(fullscreen: 0, layers: { '2' => [surface('some-shell')] }, **SIZE)
    @machine.shell.on('grim', stdout: PPM)

    assert_grim_refused(/some-shell/)
  end

  def test_when_both_backends_are_refused_both_reasons_are_given
    @machine.x_server.windows.fetch(Machine::GAME_WINDOW).depth = 30
    status, result, = shoot

    assert_equal 4, status
    assert_match(/pixel format/, result[:error][:message])
    assert_match(/compositor driver/, result[:error][:message])
  end

  def test_a_grim_that_hangs_is_reported_and_not_waited_for
    @machine.hyprland(**SIZE)
    @machine.shell.on('grim', raises: Cdctl::Shell::TimedOut.new('grim did not finish in time'))

    assert_grim_refused(/did not finish in time/)
  end
end

# The requirement is to report the dialog and stop, whichever backend could have avoided showing it.
class SystemDialogTest < Minitest::Test
  SIZE = { width: 100, height: 100 }.freeze
  DIALOG = { 'namespace' => 'some-auth-agent', 'x' => 0, 'y' => 0, 'w' => 50, 'h' => 50 }.freeze
  PPM = "P6\n100 100\n255\n".b + ("\x10\x20\x30".b * 10_000)

  def setup
    @machine = Machine.new
    @machine.full_game(**SIZE)
    @machine.hyprland(layers: { '3' => [DIALOG] }, **SIZE)
    @machine.shell.on('grim', stdout: PPM)
  end

  def teardown = @machine.destroy

  def state(directory) = Dir.glob(File.join(@machine.home, '.local/state/cdctl', directory, '*'))

  def assert_stopped(*argv)
    status, result, = @machine.run_json(*argv)

    assert_equal 3, status, argv.join(' ')
    assert_equal 'SYSTEM_DIALOG_PRESENT', result[:error][:code], argv.join(' ')
    assert_equal 'present', result[:data][:modals][:status]
    assert_match(/Never answer/, result[:next_steps].first)
  end

  def test_no_backend_takes_a_capture
    [%w[observe], %w[screenshot], %w[screenshot --backend x11], %w[screenshot --backend grim]].each do |argv|
      assert_stopped(*argv)
    end

    refute_includes @machine.x_server.request_names, 'GetImage'
    assert_empty(@machine.shell.calls.select { it.first == 'grim' })
    assert_empty state('evidence')
    assert_empty state('observations')
  end

  def test_a_locked_session_stops_it_too
    @machine.hyprland(locked: true, **SIZE)

    assert_stopped('screenshot')
  end

  def test_status_still_answers_and_names_it
    status, result, = @machine.run_json('status')

    assert_equal 0, status
    assert_equal 'present', result[:data][:modals][:status]
    assert_equal(['some-auth-agent'], result[:data][:modals][:blocking].map { it[:namespace] })
  end

  def test_a_surface_the_person_listed_does_not_stop_it
    File.write(File.join(@machine.home, 'config.yaml'), "ignored_overlay_layers: ['some-auth-agent']\n")
    @machine.env['CDCTL_CONFIG'] = File.join(@machine.home, 'config.yaml')

    assert_equal 0, @machine.run_json('screenshot').first
  end

  # X11 reads the game window alone, so a window on top is not in the file, and the result says what
  # it could not verify.
  def test_a_dialog_that_cannot_be_ruled_out_is_reported_by_the_capture
    @machine.hyprland(active_pid: 99, **SIZE)
    status, result, = @machine.run_json('screenshot')

    assert_equal 0, status
    assert_equal 'x11_get_image', result[:artifacts].first[:backend]
    assert_equal 'unverified', result[:data][:modals][:status]
    assert_includes result[:not_verified], 'system_dialogs'
  end
end
