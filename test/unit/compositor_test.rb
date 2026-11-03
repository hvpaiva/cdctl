# frozen_string_literal: true

require 'test_helper'

class CompositorTest < Minitest::Test
  def setup
    @machine = Machine.new
    @machine.full_game
  end

  def teardown = @machine.destroy

  def data = @machine.run_json('status')[1][:data]

  def layer(namespace, width: 500, height: 300)
    { 'namespace' => namespace, 'x' => 0, 'y' => 0, 'w' => width, 'h' => height }
  end

  def test_no_compositor_driver_is_a_normal_machine
    @machine.env['XDG_CURRENT_DESKTOP'] = 'GNOME'
    found = data

    assert_equal 'none', found[:compositor][:status]
    assert_equal 'GNOME', found[:compositor][:desktop]
    assert_equal 'x11_randr', found[:resolution][:display_mode][:source]
  end

  def test_without_a_driver_dialogs_are_declared_invisible
    status, result, = @machine.run_json('status')

    assert_equal 0, status
    assert_equal 'unavailable', result[:data][:modals][:status]
    assert_includes result[:not_verified], 'system_dialogs'
  end

  def test_an_installed_but_unresponsive_compositor_does_not_count
    @machine.shell.on('hyprctl', 'instances', '-j', status: 1, stderr: 'no instance')

    assert_equal 'none', data[:compositor][:status]
  end

  def test_a_compositor_that_stops_answering_is_reported_not_fatal
    @machine.hyprland
    @machine.shell.on('hyprctl', '-i', 'sig', '-j', 'monitors', raises: Cdctl::Shell::TimedOut.new('hyprctl timed out'))
    found = data

    assert_equal 'unavailable', found[:compositor][:status]
    assert_equal 'unavailable', found[:modals][:status]
    assert_equal 'x11_randr', found[:resolution][:display_mode][:source]
  end

  def test_uses_the_monitor_of_the_game
    @machine.hyprland(width: 1920, height: 1080)
    found = data

    assert_equal 'hyprland', found[:resolution][:display_mode][:source]
    assert_equal 'OUT-1', found[:compositor][:monitor]
    assert_equal 4242, found[:compositor][:game_client][:pid]
  end

  def test_an_unknown_overlay_surface_counts_as_a_dialog
    @machine.hyprland(layers: { '3' => [layer('some-auth-agent')] })
    modals = data[:modals]

    assert_equal 'present', modals[:status]
    assert_equal(['some-auth-agent'], modals[:blocking].map { it[:namespace] })
  end

  def test_notifications_do_not_count
    @machine.hyprland(layers: { '3' => [layer('mako'), layer('my-notifications'), layer('volume-osd')] })
    modals = data[:modals]

    assert_equal 'clear', modals[:status]
    assert_equal 3, modals[:ignored].size
  end

  def test_the_user_can_ignore_more_surfaces
    File.write(File.join(@machine.home, 'config.yaml'), "ignored_overlay_layers: ['my-widget*']\n")
    @machine.env['CDCTL_CONFIG'] = File.join(@machine.home, 'config.yaml')
    @machine.hyprland(layers: { '3' => [layer('my-widget-1')] })

    assert_equal 'clear', data[:modals][:status]
  end

  def test_panels_below_the_overlay_layer_do_not_count
    @machine.hyprland(layers: { '2' => [layer('some-bar')], '0' => [layer('wallpaper')] })

    assert_equal 'clear', data[:modals][:status]
  end

  def test_an_empty_surface_does_not_count
    @machine.hyprland(layers: { '3' => [layer('hidden-shell', width: 0, height: 0)] })

    assert_equal 'clear', data[:modals][:status]
  end

  def test_a_locked_session_is_a_surface_over_the_game
    @machine.hyprland(locked: true)
    modals = data[:modals]

    assert_equal 'present', modals[:status]
    assert_equal(['session_lock'], modals[:blocking].map { it[:namespace] })
  end

  def test_not_knowing_about_the_lock_is_not_clear
    @machine.hyprland
    @machine.shell.on('hyprctl', '-i', 'sig', '-j', 'locked', status: 1, stdout: 'unknown request')
    modals = data[:modals]

    assert_equal 'unverified', modals[:status]
    assert_match(/locked/, modals[:reason])
  end

  # An authentication agent can be an ordinary window, which shows only as the game losing focus.
  def test_another_active_window_cannot_be_called_clear
    @machine.hyprland(active_pid: 99)
    _, result, = @machine.run_json('status')

    assert_equal 'unverified', result[:data][:modals][:status]
    assert_includes result[:not_verified], 'system_dialogs'
    refute result[:data][:compositor][:game_active]
  end

  def test_with_no_game_there_is_nothing_for_another_window_to_cover
    other = Machine.new
    other.start_x
    other.hyprland(active_pid: 99)

    assert_equal 'clear', other.run_json('status')[1][:data][:modals][:status]
  ensure
    other&.destroy
  end

  def test_a_top_layer_surface_over_a_window_that_is_not_fullscreen_is_a_doubt
    @machine.hyprland(fullscreen: 0, layers: { '2' => [layer('some-shell')] })
    modals = data[:modals]

    assert_equal 'unverified', modals[:status]
    assert_match(/some-shell/, modals[:reason])
  end

  def test_a_top_layer_surface_beside_the_window_is_no_doubt
    @machine.hyprland(fullscreen: 0, layers: { '2' => [layer('some-bar').merge('y' => 1080)] })

    assert_equal 'clear', data[:modals][:status]
  end

  def test_a_fullscreen_window_hides_the_top_layer_in_either_way_of_writing_it
    [2, true].each do |fullscreen|
      @machine.hyprland(fullscreen:, layers: { '2' => [layer('some-bar')] })

      assert_equal 'clear', data[:modals][:status], fullscreen.to_s
    end
  end

  def test_the_user_can_ignore_a_top_layer_surface
    File.write(File.join(@machine.home, 'config.yaml'), "ignored_overlay_layers: ['my-panel']\n")
    @machine.env['CDCTL_CONFIG'] = File.join(@machine.home, 'config.yaml')
    @machine.hyprland(fullscreen: 0, layers: { '2' => [layer('my-panel')] })

    assert_equal 'clear', data[:modals][:status]
  end

  def two_monitors(left_focused: true)
    [@machine.monitor(0, 'LEFT', 1920, 1080, focused: left_focused),
     @machine.monitor(1, 'RIGHT', 2560, 1440, focused: !left_focused)]
  end

  def test_among_several_monitors_focus_does_not_name_the_one_with_the_game
    @machine.hyprland(monitors: two_monitors, client_pid: 99, active_pid: 99)
    found = data

    assert_equal 'unknown', found[:resolution][:display_mode][:status]
    refute found[:compositor].key?(:monitor)
  end

  def test_the_game_stays_on_its_monitor_when_focus_moves
    @machine.hyprland(monitors: two_monitors(left_focused: false))
    found = data

    assert_equal 'LEFT', found[:compositor][:monitor]
    assert_equal 'LEFT', found[:resolution][:display_mode][:value][:output]
  end
end
