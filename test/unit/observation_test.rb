# frozen_string_literal: true

require 'test_helper'

class ObservationTest < Minitest::Test
  def setup
    @machine = Machine.new
    @machine.full_game(width: 200, height: 100)
  end

  def teardown = @machine.destroy

  def observe = @machine.run_json('observe')[1]

  def check(id, *) = @machine.run_json('observation', 'check', id, *)

  def window = @machine.x_server.windows.fetch(Machine::GAME_WINDOW)

  def test_an_observation_names_a_capture_and_a_geometry
    result = observe

    assert_match(/\Aobs-[0-9a-f]{16}\z/, result[:data][:observation_id])
    assert_equal 200, result[:data][:fingerprint][:width]
    assert_path_exists result[:artifacts].first[:path]
    assert_equal 200, result[:data][:resolution][:capture][:value][:width]
  end

  def test_the_screen_is_honestly_unknown
    result = observe

    assert_equal 'unknown', result[:data][:screen][:status]
    assert_includes result[:not_verified], 'game.screen'
  end

  def test_an_unchanged_game_keeps_the_observation_valid
    id = observe[:data][:observation_id]
    status, result, = check(id)

    assert_equal 0, status
    assert result[:data][:valid]
    assert_empty result[:data][:differences]
  end

  def test_a_new_window_size_invalidates_it
    id = observe[:data][:observation_id]
    window.width = 300
    status, result, = check(id)

    assert_equal 3, status
    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_equal [{ field: 'width', was: 200, now: 300 }], result[:data][:differences]
  end

  def test_a_moved_window_invalidates_it
    id = observe[:data][:observation_id]
    window.x = 5

    assert_equal 'RESOLUTION_CHANGED', check(id)[1][:error][:code]
  end

  def test_a_new_monitor_mode_invalidates_it
    @machine.hyprland(width: 200, height: 100)
    id = observe[:data][:observation_id]
    @machine.hyprland(width: 400, height: 100)
    _, result, = check(id)

    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_equal(['display'], result[:data][:differences].map { it[:field] })
  end

  def test_a_restarted_game_is_another_target
    id = observe[:data][:observation_id]
    @machine.run_game(start_ticks: 9999)

    assert_equal 'TARGET_CHANGED', check(id)[1][:error][:code]
  end

  def test_a_closed_game_is_another_target
    id = observe[:data][:observation_id]
    FileUtils.remove_entry(File.join(@machine.proc_root, '4242'))

    assert_equal 'TARGET_CHANGED', check(id)[1][:error][:code]
  end

  # The same window can hold another layout once the game applied these.
  def test_a_new_stored_resolution_invalidates_it
    @machine.write_options(OptionFiles.sample, modified_at: Machine::LONG_AGO)
    id = observe[:data][:observation_id]
    @machine.write_options(OptionFiles.sample(viewport: '640 480'))
    _, result, = check(id)

    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_equal(['stored_resolution'], result[:data][:differences].map { it[:field] })
  end

  def test_a_new_hud_scale_invalidates_it
    @machine.write_options(OptionFiles.sample(hud_scale: 90), modified_at: Machine::LONG_AGO)
    id = observe[:data][:observation_id]
    @machine.write_options(OptionFiles.sample(hud_scale: 80))
    _, result, = check(id)

    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_equal(['hud_scale'], result[:data][:differences].map { it[:field] })
  end

  def test_what_could_not_be_compared_is_listed
    id = observe[:data][:observation_id]
    _, result, = check(id)

    assert result[:data][:valid]
    assert_includes result[:not_verified], 'game.stored_resolution'
    assert_includes result[:not_verified], 'game.screen'
    assert_includes result[:not_verified], 'system_dialogs'
  end

  def test_a_display_that_cannot_be_read_is_not_called_unchanged
    @machine.hyprland(width: 200, height: 100, client_pid: 99, active_pid: 99,
                      monitors: [@machine.monitor(0, 'LEFT', 200, 100), @machine.monitor(1, 'RIGHT', 200, 100)])
    id = observe[:data][:observation_id]
    _, result, = check(id)

    assert result[:data][:valid]
    assert_includes result[:not_verified], 'display_mode'
  end

  def test_a_new_screen_invalidates_it_where_no_monitor_mode_can_be_read
    @machine.x_server.extensions['XWAYLAND'] = 150
    id = observe[:data][:observation_id]
    @machine.x_server.outputs = [@machine.x_server.outputs.first.merge(width: 2560)]
    _, result, = check(id)

    assert_equal 'RESOLUTION_CHANGED', result[:error][:code]
    assert_equal(['screen'], result[:data][:differences].map { it[:field] })
  end

  def test_an_unreachable_x_server_is_not_another_target
    id = observe[:data][:observation_id]
    @machine.x11_opener = @machine.method(:no_x_server)
    status, result, = check(id)

    assert_equal 3, status
    assert_equal 'WINDOW_NOT_FOUND', result[:error][:code]
    assert_match(/X11 is not reachable/, result[:error][:message])
  end

  def test_a_silent_x_server_is_a_timeout_and_not_another_target
    id = observe[:data][:observation_id]
    @machine.x_server.client_timeout = 0.05
    @machine.x_server.silent = true
    status, result, = check(id)

    assert_equal 1, status
    assert_equal 'TIMEOUT', result[:error][:code]
  end

  def test_two_processes_are_ambiguous_and_not_another_target
    id = observe[:data][:observation_id]
    @machine.run_game(pid: 4243)

    assert_equal 'TARGET_AMBIGUOUS', check(id)[1][:error][:code]
  end

  def test_an_old_observation_can_be_refused
    id = observe[:data][:observation_id]
    status, result, = check(id, '--max-age', '0')

    assert_equal 3, status
    assert_equal 'OBSERVATION_STALE', result[:error][:code]
  end

  def test_an_unknown_id_is_reported
    assert_equal 'OBSERVATION_NOT_FOUND', check('obs-0000000000000000')[1][:error][:code]
  end

  def test_an_id_cannot_walk_out_of_the_store
    target = File.join(@machine.home, '.local/state/cdctl/secret.json')
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, '{}')

    assert_equal 'OBSERVATION_NOT_FOUND', check('../secret')[1][:error][:code]
  end
end
