# frozen_string_literal: true

require 'test_helper'

# Each case is a state seen on a real installation, rebuilt with made-up data.
class ResolutionTest < Minitest::Test
  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def resolution = @machine.run_json('status')[1][:data][:resolution]

  # A window that fills the screen proves nothing here: a mode changed after the launch leaves one
  # around an image of the old size, and a later look cannot see what happened before the first.
  def test_with_nothing_stored_a_filled_window_does_not_prove_the_image_fills_it
    @machine.full_game(width: 3440, height: 1440, options: OptionFiles.sample)

    2.times do
      found = resolution

      assert_equal 'unknown', found[:presentation][:status]
      assert_match(/did not launch it/, found[:presentation][:reason])
      assert_nil found[:configured_override][:value]
    end
  end

  def test_a_stored_resolution_equal_to_the_window_is_native
    @machine.full_game(width: 2560, height: 1440, options: OptionFiles.sample(viewport: '2560 1440'))
    found = resolution[:presentation]

    assert_equal({ mode: 'native' }, found[:value])
    assert_equal 'inferred', found[:confidence]
  end

  def test_an_option_file_written_after_the_launch_says_nothing_about_this_process
    @machine.full_game(width: 3440, height: 1440)
    @machine.write_options(OptionFiles.sample(viewport: '2560 1440'))
    found = resolution

    assert_equal({ width: 2560, height: 1440 }, found[:configured_override][:value])
    assert_equal 'unknown', found[:presentation][:status]
    assert_match(/after this process started/, found[:presentation][:reason])
  end

  def test_a_process_with_no_known_start_cannot_be_compared_with_the_file
    File.write(File.join(@machine.proc_root, 'stat'), "cpu 0\n")
    @machine.full_game(width: 3440, height: 1440, options: OptionFiles.sample(viewport: '2560 1440'))

    assert_match(/after this process started/, resolution[:presentation][:reason])
  end

  def test_a_stored_resolution_without_its_value_is_not_an_absent_one
    options = OptionFiles.sample.sub('<OptionInt Name="_uiHudScale"',
                                     %(<OptionInt2Vector Name="_viewportSize"/>\n<OptionInt Name="_uiHudScale"))
    @machine.full_game(width: 3440, height: 1440, options:)
    found = resolution

    assert_equal 'unknown', found[:configured_override][:status]
    assert_match(/has no _value/, found[:configured_override][:reason])
    assert_equal 'unknown', found[:presentation][:status]
  end

  def test_a_file_with_no_settings_is_not_a_file_that_omits_them
    @machine.full_game(options: "<EngineOptionSave/>\n")
    data = @machine.run_json('status')[1][:data]

    assert_equal 'unknown', data[:resolution][:configured_override][:status]
    assert_equal 'unknown', data[:resolution][:hud_scale][:status]
    assert_equal 'unavailable', data[:settings][:state]
  end

  def test_a_stored_resolution_under_a_larger_window_is_stretched_by_the_exact_factor
    @machine.full_game(width: 3440, height: 1440, options: OptionFiles.sample(viewport: '2560 1440'))
    value = resolution[:presentation][:value]

    assert_equal 'stretched', value[:mode]
    assert_in_delta 1.34375, value[:scale_x]
    assert_in_delta 1.0, value[:scale_y]
    assert_equal({ width: 2560, height: 1440 }, value[:rendered])
  end

  def test_the_same_window_size_can_mean_two_resolutions
    @machine.full_game(width: 3440, height: 1440, options: OptionFiles.sample(viewport: '2560 1440'))
    stretched = resolution
    other = Machine.new
    other.full_game(width: 3440, height: 1440, options: OptionFiles.sample)

    assert_equal stretched[:window][:value], other.run_json('status')[1][:data][:resolution][:window][:value]
    refute_equal stretched[:presentation][:value],
                 other.run_json('status')[1][:data][:resolution][:presentation][:value]
  ensure
    other&.destroy
  end

  def test_a_game_inside_a_nested_compositor_says_so
    @machine.start_x(width: 2560, height: 1440)
    @machine.install_game(@machine.steam_root, options: OptionFiles.sample)
    @machine.add_process(50, comm: 'gamescope-wl', argv: ['gamescope'])
    @machine.run_game(parent: 50)
    @machine.game_window(width: 2560, height: 1440)
    found = resolution

    assert_equal({ mode: 'nested' }, found[:presentation][:value])
    assert_equal 'unknown', found[:display_mode][:status]
    assert_equal 2560, found[:game_screen][:value][:width]
  end

  def test_the_active_resolution_stays_unknown_whatever_the_window_says
    @machine.full_game(options: OptionFiles.sample)

    assert_equal 'unknown', resolution[:active][:status]
    assert_includes @machine.run_json('status')[1][:not_verified], 'game.active_resolution'
  end

  def test_the_upscaler_is_reported_apart_from_the_resolution
    @machine.full_game(options: OptionFiles.sample(upscale: '50%', hud_scale: 80))
    found = resolution

    assert_equal '50%', found[:render_scale][:value]
    assert_equal 80, found[:hud_scale][:value]
  end

  def test_the_first_look_cannot_vouch_for_the_launch
    @machine.full_game(options: OptionFiles.sample)
    found = resolution

    assert_equal 'unknown', found[:coherence][:status]
    assert_match(/first observation/, found[:coherence][:reason])
    assert_equal 'unknown', found[:launch_display_mode][:status]
  end

  def test_a_later_look_with_the_same_geometry_is_consistent
    @machine.full_game(options: OptionFiles.sample)
    resolution

    assert_equal 'consistent', resolution[:coherence][:value][:state]
  end

  def test_a_mode_change_with_the_game_open_is_detected
    @machine.full_game(width: 1920, height: 1080, options: OptionFiles.sample)
    @machine.hyprland(width: 1920, height: 1080)
    resolution
    window = @machine.x_server.windows.fetch(Machine::GAME_WINDOW)
    window.width = 3440
    window.height = 1440
    @machine.hyprland(width: 3440, height: 1440)
    found = resolution

    assert_equal 'display_changed', found[:coherence][:value][:state]
    assert_equal 'unknown', found[:presentation][:status]
    assert_equal(%w[window display], found[:coherence][:value][:changes].map { it[:field] })
  end

  def test_a_window_that_changes_alone_is_not_a_display_change
    @machine.full_game(width: 1920, height: 1080, options: OptionFiles.sample(viewport: '1280 720'))
    window = @machine.x_server.windows.fetch(Machine::GAME_WINDOW)
    window.width = 1280
    window.height = 720
    resolution
    window.width = 1920
    window.height = 1080
    found = resolution

    assert_equal 'window_changed', found[:coherence][:value][:state]
    assert_equal 'stretched', found[:presentation][:value][:mode]
  end

  def nested_game
    @machine.start_x(width: 2560, height: 1440)
    @machine.install_game(@machine.steam_root, options: OptionFiles.sample)
    @machine.add_process(50, comm: 'gamescope-wl', argv: ['gamescope'])
    @machine.run_game(parent: 50)
    @machine.game_window(width: 2560, height: 1440)
  end

  def test_a_nested_game_cannot_vouch_for_a_display_it_never_saw
    nested_game
    resolution
    found = resolution[:coherence]

    assert_equal 'unknown', found[:status]
    assert_match(/cannot be detected/, found[:reason])
  end

  def test_a_nested_game_has_no_display_mode_even_with_a_compositor_present
    nested_game
    @machine.hyprland(client_pid: 50, active_pid: 50, width: 3440, height: 1440)

    assert_equal 'unknown', resolution[:display_mode][:status]
  end

  def test_a_display_read_another_way_cannot_be_compared
    @machine.full_game(options: OptionFiles.sample)
    resolution
    @machine.hyprland
    found = resolution

    assert_equal 'hyprland', found[:display_mode][:source]
    assert_equal 'unknown', found[:coherence][:status]
  end

  def test_xwayland_reports_its_own_view_and_not_the_monitor_mode
    @machine.full_game(width: 1920, height: 1080, options: OptionFiles.sample)
    @machine.x_server.extensions['XWAYLAND'] = 150
    found = resolution

    assert_equal 'unknown', found[:display_mode][:status]
    assert_match(/Xwayland/, found[:display_mode][:reason])
    assert_equal 1920, found[:game_screen][:value][:width]
  end

  def test_xwayland_still_shows_that_the_screen_changed
    @machine.full_game(width: 1920, height: 1080, options: OptionFiles.sample)
    @machine.x_server.extensions['XWAYLAND'] = 150
    resolution

    assert_equal 'consistent', resolution[:coherence][:value][:state]
    @machine.x_server.outputs = [@machine.x_server.outputs.first.merge(width: 2560, height: 1440)]

    assert_equal 'display_changed', resolution[:coherence][:value][:state]
  end

  def two_outputs
    common = { y: 0, height: 1000, dot_clock: 60_000_000, h_total: 1000, v_total: 1000 }
    [{ name: 'LEFT', x: 0, width: 1000, **common }, { name: 'RIGHT', x: 1000, width: 1000, **common }]
  end

  def test_the_screen_is_the_one_holding_the_window
    @machine.start_x
    @machine.x_server.outputs = two_outputs
    @machine.install_game(@machine.steam_root)
    @machine.run_game
    @machine.game_window(width: 800, height: 600, x: 1100, y: 0)

    assert_equal 'RIGHT', resolution[:game_screen][:value][:output]
  end

  def test_among_several_screens_none_is_named_without_a_window
    @machine.start_x
    @machine.x_server.outputs = two_outputs
    found = resolution

    assert_equal 'unknown', found[:game_screen][:status]
    assert_equal 'unknown', found[:display_mode][:status]
  end

  def test_a_closed_game_still_reports_the_display_and_the_file
    @machine.start_x
    @machine.install_game(@machine.steam_root, options: OptionFiles.sample(viewport: '1600 900'))
    found = resolution

    assert_equal 1920, found[:display_mode][:value][:width]
    assert_equal({ width: 1600, height: 900 }, found[:configured_override][:value])
    assert_equal 'unknown', found[:presentation][:status]
  end

  def test_a_missing_option_file_does_not_stop_the_report
    @machine.full_game
    found = resolution

    assert_equal 'unknown', found[:configured_override][:status]
    assert_equal 'unknown', found[:presentation][:status]
  end
end
