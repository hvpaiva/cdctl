# frozen_string_literal: true

require 'test_helper'

class InputKeysTest < Minitest::Test
  KEYS = Cdctl::Input::Keys

  def test_names_become_keysyms
    assert_equal 0xFF1B, KEYS.keysym('Escape')
    assert_equal 'e'.ord, KEYS.keysym('e')
    assert_equal 'e'.ord, KEYS.keysym('E')
    assert_equal '7'.ord, KEYS.keysym('7')
    assert_equal 0xFFBE, KEYS.keysym('F1')
    assert_equal 0xFFBE + 23, KEYS.keysym('F24')
    assert_equal 0x20, KEYS.keysym('space')
  end

  def test_an_unknown_name_is_a_usage_error
    ['F25', 'F0', 'Super_L', 'ee', '', "e\n"].each do |name|
      assert_raises(Cdctl::CLI::UsageError, name.inspect) { KEYS.keysym(name) }
    end
  end
end

module InputAssertions
  def assert_nothing_sent = assert_empty(@x.fake_inputs)

  def assert_all_released
    assert_empty @x.keys_down
    assert_empty @x.buttons_down
  end

  def assert_refused(code, status, result)
    assert_equal code, result[:error][:code]
    assert_equal 3, status
    assert_nothing_sent
  end
end

class InputCommandTest < Minitest::Test
  include SchemaAssertions
  include InputAssertions

  KEY_H = FakeXServer.keycode('h'.ord)
  KEY_PRESS = 2
  KEY_RELEASE = 3
  BUTTON_PRESS = 4
  BUTTON_RELEASE = 5
  MOTION = 6

  def setup
    @machine = Machine.new
    @machine.playable_game
    @x = @machine.x_server
    @token = @machine.lease_token
  end

  def teardown = @machine.destroy

  def input(*, token: @token)
    @machine.run_json('input', *, *(token ? ['--token', token] : []))
  end

  def key(*, **) = input('key', 'h', '--no-capture', *, **)

  def observation = @machine.run_json('observe')[1][:data][:observation_id]

  # Refusals ------------------------------------------------------------------------------------

  def test_no_token_means_nothing_is_sent
    released = @machine.run_json('lease', 'release', '--token', @token)

    assert_equal 0, released.first
    status, result, = key(token: nil)

    assert_refused 'LEASE_REQUIRED', status, result
  end

  def test_another_owner_means_nothing_is_sent
    status, result, = key(token: nil)

    assert_refused 'LEASE_BUSY', status, result
  end

  def test_a_token_from_before_a_takeover_means_nothing_is_sent
    @machine.run_json('lease', 'acquire', '--owner', 'other', '--purpose', 'mine', '--takeover', '--force', '--reason',
                      'testing')
    status, result, = key

    assert_refused 'LEASE_LOST', status, result
  end

  def test_the_token_can_come_from_the_environment
    @machine.env['CDCTL_LEASE_TOKEN'] = @token

    assert_equal 0, key(token: nil).first
  end

  def test_a_closed_game_means_nothing_is_sent
    FileUtils.rm_rf(File.join(@machine.proc_root, '4242'))
    status, result, = key

    assert_refused 'GAME_NOT_RUNNING', status, result
  end

  def test_a_game_without_focus_means_nothing_is_sent
    @x.focus = 0
    status, result, = key

    assert_refused 'FOCUS_LOST', status, result
  end

  def test_another_active_window_means_nothing_is_sent
    @machine.hyprland(active_pid: 777)
    status, result, = key

    assert_refused 'FOCUS_LOST', status, result
    refute_includes result.to_s, Machine::ANOTHER_WINDOW_TITLE
  end

  def test_a_dialog_over_the_game_means_nothing_is_sent
    @machine.hyprland(layers: { '3' => [{ 'namespace' => 'polkit-agent', 'x' => 0, 'y' => 0, 'w' => 500,
                                          'h' => 300 }] })
    status, result, = key

    assert_refused 'SYSTEM_DIALOG_PRESENT', status, result
    assert_includes result[:error][:message], 'polkit-agent'
  end

  def test_a_locked_session_means_nothing_is_sent
    @machine.hyprland(locked: true)
    status, result, = key

    assert_refused 'SYSTEM_DIALOG_PRESENT', status, result
  end

  def test_a_notification_does_not_stop_input
    @machine.hyprland(layers: { '3' => [{ 'namespace' => 'some-notifications', 'x' => 0, 'y' => 0, 'w' => 100,
                                          'h' => 80 }] })

    assert_equal 0, key.first
  end

  def test_a_desktop_that_hides_its_dialogs_needs_an_explicit_flag
    @machine.shell.on('hyprctl', 'instances', '-j', status: 1)
    status, result, = key

    assert_refused 'SYSTEM_DIALOG_PRESENT', status, result
    refute_empty result[:next_steps]

    status, result, = key('--allow-unverified-dialogs')

    assert_equal 0, status
    assert_includes result[:not_verified], 'system_dialogs'
    refute_empty @x.fake_inputs
  end

  def test_a_key_someone_else_holds_means_nothing_is_sent
    @x.keys_down << 99
    status, result, = key

    assert_refused 'USER_INTERFERENCE', status, result
    assert_equal({ keys: 1, buttons: false }, result[:error][:details])
    refute_includes result.to_s, '99'
  end

  def test_a_button_someone_else_holds_means_nothing_is_sent
    @x.buttons_down << 1
    status, result, = key

    assert_refused 'USER_INTERFERENCE', status, result
  end

  def test_a_server_without_xtest_cannot_send
    @x.extensions.delete('XTEST')
    status, result, = key

    assert_equal 4, status
    assert_equal 'UNSUPPORTED_BACKEND', result[:error][:code]
    assert_nothing_sent
  end

  def test_a_layout_without_that_key_says_so
    status, result, = @machine.run_json('input', 'key', 'F2', '--no-capture', '--token', @token)

    assert_refused 'PRECONDITION_FAILED', status, result
  end

  def test_the_command_line_is_checked_before_anything_else
    { %w[--hold-ms 0] => 'hold-ms', %w[--hold-ms 10001] => 'hold-ms', %w[--hold-ms x] => 'hold-ms',
      %w[--repeat 0] => 'repeat', %w[--repeat 21] => 'repeat', %w[--gap-ms 2001] => 'gap-ms',
      %w[--settle-ms 10001] => 'settle-ms' }.each do |arguments, flag|
      status, result, = key(*arguments)

      assert_equal 2, status, arguments.join(' ')
      assert_includes result[:error][:message], flag
    end
    assert_equal 2, input('key', 'Super_L', '--no-capture').first
    assert_nothing_sent
  end

  # A key --------------------------------------------------------------------------------------

  def test_a_key_is_pressed_and_released_once
    status, result, = input('key', 'h', '--hold-ms', '10')

    assert_equal 0, status
    assert_equal([[KEY_PRESS, KEY_H], [KEY_RELEASE, KEY_H]], @x.fake_inputs.map { it.first(2) })
    assert_all_released
    assert_valid 'input.key', result
  end

  def test_the_answer_says_it_cannot_tell_what_the_key_did
    _, result, = input('key', 'h', '--hold-ms', '10')

    assert_nil result[:changed]
    assert_equal 'caller_required', result[:verification][:method]
    assert_equal result[:artifacts].first[:path], result[:verification][:screenshot]
    assert_includes result[:not_verified], 'input.result'
    assert_equal result[:before], result[:after]
    refute_nil result[:before][:window]
  end

  def test_the_action_reports_what_really_happened
    _, result, = key('--hold-ms', '30')
    action = result[:actions].first

    assert_equal %w[key h cdctl], action.values_at(:type, :key, :released_by)
    assert_equal KEY_H, action[:keycode]
    assert_operator action[:held_ms], :>=, 30
    assert_operator action[:held_ms], :<, 2000
    refute_empty action[:pressed_at]
    refute_empty action[:released_at]
  end

  def test_the_answer_never_holds_the_token
    _, out, = @machine.run('input', 'key', 'h', '--hold-ms', '5', '--no-capture', '--token', @token, '--json')

    refute_includes out, @token
  end

  def test_repeat_presses_that_many_times
    status, result, = key('--hold-ms', '5', '--repeat', '3', '--gap-ms', '5')

    assert_equal 0, status
    assert_equal 3, result[:actions].size
    assert_equal 3, @x.fake_input_kinds.count(KEY_PRESS)
    assert_equal 3, @x.fake_input_kinds.count(KEY_RELEASE)
    assert_all_released
  end

  def test_every_press_checks_again
    pressed = 0
    @x.on_fake_input = lambda do |type, _|
      pressed += 1 if type == KEY_RELEASE
      @x.focus = 0 if pressed == 1
    end
    status, result, = key('--hold-ms', '5', '--repeat', '3', '--gap-ms', '5')

    assert_equal 3, status
    assert_equal 'FOCUS_LOST', result[:error][:code]
    assert_equal 1, @x.fake_input_kinds.count(KEY_PRESS)
    assert_equal 1, result[:actions].size
    assert_all_released
  end

  def test_a_good_observation_is_accepted_and_a_bad_one_refused
    id = observation

    assert_equal 0, key('--hold-ms', '5', '--observation', id).first
    @x.fake_inputs.clear
    @x.windows[Machine::GAME_WINDOW].width = 1280
    status, result, = key('--observation', id)

    assert_refused 'RESOLUTION_CHANGED', status, result
  end

  def test_an_observation_older_than_allowed_is_refused
    id = observation
    status, result, = key('--observation', id, '--max-age', '0')

    assert_refused 'OBSERVATION_STALE', status, result
  end

  def test_an_observation_that_does_not_exist_is_refused
    status, result, = key('--observation', 'obs-0000000000000000')

    assert_refused 'OBSERVATION_NOT_FOUND', status, result
  end

  # During a hold -------------------------------------------------------------------------------

  def press_then
    @x.on_fake_input = ->(type, _) { yield if type == KEY_PRESS }
  end

  def test_losing_the_focus_during_a_hold_releases_at_once
    press_then { @x.focus = 0 }
    status, result, = key('--hold-ms', '5000')

    assert_equal 'FOCUS_LOST', result[:error][:code]
    assert_equal 3, status
    assert_all_released
    assert_operator result[:actions].first[:held_ms], :<, 2000
    assert_nil result[:changed]
    refute_nil result[:target]
  end

  def test_a_person_typing_during_a_hold_releases_at_once
    press_then { @x.input_from_a_person(:key_press) }
    status, result, = key('--hold-ms', '5000')

    assert_equal 'USER_INTERFERENCE', result[:error][:code]
    assert_equal 3, status
    assert_equal 1, result[:error][:details][:key_press]
    assert_all_released
    assert_operator result[:actions].first[:held_ms], :<, 2000
  end

  def test_a_person_clicking_during_a_hold_releases_at_once
    press_then { @x.input_from_a_person(:button_press, device: FakeXServer::REAL_POINTER) }
    _, result, = key('--hold-ms', '5000')

    assert_equal 'USER_INTERFERENCE', result[:error][:code]
    assert_all_released
  end

  def test_a_little_mouse_motion_is_tolerated_and_more_is_not
    press_then { 2.times { @x.input_from_a_person(:motion) } }
    status, result, = key('--hold-ms', '40')

    assert_equal 0, status
    assert_equal 2, result[:data][:activity][:other_sources][:motion]

    press_then { 5.times { @x.input_from_a_person(:motion) } }
    _, result, = key('--hold-ms', '5000')

    assert_equal 'USER_INTERFERENCE', result[:error][:code]
    assert_all_released
  end

  def test_another_program_sending_through_xtest_is_noticed
    press_then { @x.input_from_a_person(:key_press, device: FakeXServer::XTEST_KEYBOARD) }
    _, result, = key('--hold-ms', '5000')

    assert_equal 'USER_INTERFERENCE', result[:error][:code]
    assert_includes result[:error][:message], 'XTEST'
    assert_equal 1, result[:error][:details][:extra_xtest]
    assert_all_released
  end

  def test_the_game_exiting_during_a_hold_releases_at_once
    press_then { FileUtils.rm_rf(File.join(@machine.proc_root, '4242')) }
    _, result, = key('--hold-ms', '5000')

    assert_equal 'TARGET_CHANGED', result[:error][:code]
    assert_all_released
  end

  def test_a_dialog_opening_during_a_long_hold_releases
    layers = { '3' => [{ 'namespace' => 'polkit-agent', 'x' => 0, 'y' => 0, 'w' => 500, 'h' => 300 }] }
    press_then { @machine.hyprland(layers:) }
    _, result, = key('--hold-ms', '5000')

    assert_equal 'SYSTEM_DIALOG_PRESENT', result[:error][:code]
    assert_all_released
    assert_operator result[:actions].first[:held_ms], :<, 2000
  end

  def test_a_real_signal_during_a_hold_releases_and_answers
    press_then { Process.kill('TERM', Process.pid) }
    status, result, = key('--hold-ms', '5000')

    assert_equal 130, status
    assert_equal 'INTERRUPTED', result[:error][:code]
    assert_all_released
    assert_equal 1, result[:actions].size
  end

  def test_a_press_the_server_refuses_is_a_failure_and_no_journal_stays
    @x.refuse_fake_input = true
    status, result, = key

    assert_equal 1, status
    assert_equal 'INTERNAL_ERROR', result[:error][:code]
  ensure
    @x.refuse_fake_input = false
  end

  def test_a_game_closing_right_after_the_key_is_still_an_answer
    @x.on_fake_input = ->(type, _) { FileUtils.rm_rf(File.join(@machine.proc_root, '4242')) if type == KEY_RELEASE }
    status, result, = input('key', 'h', '--hold-ms', '5')

    assert_equal 0, status
    assert_empty result[:artifacts]
    assert_nil result[:after]
    assert_nil result[:verification][:screenshot]
  end

  # Coordinates --------------------------------------------------------------------------------

  def test_a_click_moves_and_clicks_in_window_coordinates
    @machine.destroy
    @machine = Machine.new
    @machine.install_game(@machine.steam_root)
    @machine.run_game
    @machine.start_x(width: 3000, height: 2000)
    @machine.game_window(width: 1000, height: 700, x: 200, y: 100)
    @machine.hyprland(width: 1000, height: 700, x: 200, y: 100, fullscreen: 2)
    @x = @machine.x_server
    @token = @machine.lease_token
    status, result, = input('click', '--x', '10', '--y', '20', '--observation', observation, '--no-capture')

    assert_equal 0, status
    assert_equal [[MOTION, 0, 210, 120], [BUTTON_PRESS, 1], [BUTTON_RELEASE, 1]],
                 [@x.fake_inputs.first, *@x.fake_inputs.drop(1).map { it.first(2) }]
    assert_equal(%w[move click], result[:actions].map { it[:type] })
    assert_valid 'input.click', result
    assert_all_released
  end

  def test_a_click_needs_an_observation
    status, result, = input('click', '--x', '10', '--y', '20', '--no-capture')

    assert_equal 2, status
    assert_includes result[:error][:message], '--observation'
    assert_nothing_sent
  end

  def test_a_click_outside_the_window_is_refused
    id = observation
    [%w[1920 10], %w[10 1080], %w[5000 5000]].each do |x, y|
      status, result, = input('click', '--x', x, '--y', y, '--observation', id, '--no-capture')

      assert_refused 'PRECONDITION_FAILED', status, result
    end
  end

  def test_a_coordinate_that_is_not_a_number_is_a_usage_error
    id = observation

    assert_equal 2, input('click', '--x', 'a', '--y', '1', '--observation', id).first
    assert_equal 2, input('click', '--x', '-1', '--y', '1', '--observation', id).first
    assert_nothing_sent
  end

  def test_a_click_after_the_window_changed_is_refused
    id = observation
    @x.windows[Machine::GAME_WINDOW].height = 720
    status, result, = input('click', '--x', '1', '--y', '1', '--observation', id)

    assert_refused 'RESOLUTION_CHANGED', status, result
  end

  def test_a_click_after_the_game_restarted_is_refused
    id = observation
    @machine.run_game(start_ticks: 6000)
    status, result, = input('click', '--x', '1', '--y', '1', '--observation', id)

    assert_refused 'TARGET_CHANGED', status, result
  end

  def test_a_right_click_uses_that_button
    input('click', '--x', '1', '--y', '1', '--button', 'right', '--observation', observation, '--no-capture')

    assert_includes @x.fake_inputs.map { it.first(2) }, [BUTTON_PRESS, 3]
  end

  def test_an_unknown_button_is_a_usage_error
    assert_equal 2, input('click', '--x', '1', '--y', '1', '--button', 'thumb', '--observation', observation).first
  end

  def test_move_only_moves
    status, result, = input('move', '--x', '5', '--y', '6', '--observation', observation, '--no-capture')

    assert_equal 0, status
    assert_equal [[MOTION, 0, 5, 6]], @x.fake_inputs
    assert_valid 'input.move', result
  end

  def test_scroll_turns_the_wheel_that_many_steps
    status, result, = input('scroll', '--x', '5', '--y', '6', '--direction', 'down', '--steps', '2', '--observation',
                            observation, '--no-capture')

    assert_equal 0, status
    assert_equal(2, @x.fake_inputs.count { it.first(2) == [BUTTON_PRESS, 5] })
    assert_equal(2, @x.fake_inputs.count { it.first(2) == [BUTTON_RELEASE, 5] })
    assert_valid 'input.scroll', result
    assert_all_released
  end

  def test_scroll_checks_its_flags
    assert_equal 2, input('scroll', '--x', '5', '--y', '6', '--observation', 'obs').first
    assert_equal 2, input('scroll', '--x', '5', '--y', '6', '--direction', 'sideways', '--observation', 'obs').first
    assert_equal 2, input('scroll', '--x', '5', '--y', '6', '--direction', 'up', '--steps', '21', '--observation',
                          'obs').first
  end

  # What is watched -----------------------------------------------------------------------------

  def test_the_answer_reports_other_sources
    _, result, = key('--hold-ms', '5')

    assert_equal({ watched: true, other_sources: { key_press: 0, button_press: 0, motion: 0 } },
                 result[:data][:activity])
    refute_includes result[:not_verified], 'input.no_other_source'
  end

  def test_a_server_without_xi2_is_said_not_to_be_watched
    @x.xi2_version = [1, 5]
    status, result, = key('--hold-ms', '5')

    assert_equal 0, status
    refute result[:data][:activity][:watched]
    assert_includes result[:not_verified], 'input.no_other_source'
  end

  def test_a_server_without_xinput_is_said_not_to_be_watched
    @x.extensions.delete('XInputExtension')
    status, result, = key('--hold-ms', '5')

    assert_equal 0, status
    refute result[:data][:activity][:watched]
  end

  # Human output --------------------------------------------------------------------------------

  def test_human_output_says_what_was_sent
    status, out, = @machine.run('input', 'key', 'h', '--hold-ms', '5', '--token', @token)

    assert_equal 0, status
    assert_match(/Sent\s+h for \d+ ms/, out)
    assert_match(/Check\s+caller required/, out)
    assert_match(/input\.result/, out)
  end

  def test_human_output_of_a_click
    status, out, = @machine.run('input', 'click', '--x', '1', '--y', '2', '--observation', observation, '--no-capture',
                                '--token', @token)

    assert_equal 0, status
    assert_match(/move to 1,2, left click at 1,2/, out)
    assert_match(/Capture\s+none taken/, out)
  end

  def test_help_lists_input_with_its_safety
    status, out, = @machine.run('input', 'key', '--help')

    assert_equal 0, status
    assert_match(/survives an error, a signal and even SIGKILL/, out)
  end
end

class InputJournalTest < Minitest::Test
  include SchemaAssertions

  KEY_H = FakeXServer.keycode('h'.ord)

  def setup
    @machine = Machine.new
    @machine.playable_game
    @x = @machine.x_server
    @token = @machine.lease_token
    @journal = Cdctl::Input::Journal.new(Cdctl::Paths.new(@machine.env).input_dir)
  end

  def teardown = @machine.destroy

  def leave_held(*items)
    items.select { it[:kind] == 'key' }.each { @x.keys_down << it[:code] }
    @journal.write(held: items, pressed_at: '2026-11-03T10:00:00.000Z', request_id: 'earlier',
                   owner: { pid: 999_999, start_ticks: 1 }, sentinel: { pid: 999_998, start_ticks: 1 })
  end

  def test_status_reports_what_was_left_held_without_touching_it
    leave_held({ kind: 'key', code: KEY_H })
    _, result, = @machine.run_json('status')

    assert_equal 'left_held', result[:data][:input][:state]
    assert_equal 1, result[:data][:input][:count]
    assert_valid 'status', result
    refute_empty result[:next_steps]
    assert_empty @x.fake_inputs
    assert_equal [KEY_H], @x.keys_down
  end

  def test_status_says_clear_with_no_journal
    _, result, = @machine.run_json('status')

    assert_equal({ state: 'clear' }, result[:data][:input])
    assert_empty result[:next_steps]
  end

  def test_input_release_releases_what_the_journal_names_and_only_that
    leave_held({ kind: 'key', code: KEY_H }, { kind: 'button', code: 1 })
    @x.buttons_down << 1
    @x.keys_down << 50
    status, result, = @machine.run_json('input', 'release', '--token', @token)

    assert_equal 0, status
    assert_equal 2, result[:data][:released]
    assert_equal 1, result[:data][:keys_still_held]
    assert_equal [50], @x.keys_down
    assert_empty @x.buttons_down
    assert result[:changed]
    assert_nil @journal.read
    assert_valid 'input.release', result
  end

  def test_input_release_with_nothing_held_changes_nothing
    status, result, = @machine.run_json('input', 'release', '--token', @token)

    assert_equal 0, status
    refute result[:changed]
    assert_empty result[:actions]
    assert_empty @x.fake_inputs
  end

  def test_input_release_needs_the_lease
    leave_held({ kind: 'key', code: KEY_H })
    status, result, = @machine.run_json('input', 'release')

    assert_equal 3, status
    assert_equal 'LEASE_BUSY', result[:error][:code]
    assert_equal [KEY_H], @x.keys_down
  end

  def test_the_next_input_settles_it_first
    leave_held({ kind: 'key', code: KEY_H })
    status, result, = @machine.run_json('input', 'key', 'a', '--hold-ms', '5', '--no-capture', '--token', @token)

    assert_equal 0, status
    assert_equal 1, result[:data][:recovered][:released]
    assert_equal 'earlier', result[:data][:recovered][:request_id]
    assert_empty @x.keys_down
    assert_equal 3, @x.fake_inputs.size
  end

  def test_a_live_owner_is_left_alone
    owner = { pid: Process.pid, start_ticks: 5 }
    @machine.add_process(Process.pid, comm: 'cdctl', argv: ['cdctl'], start_ticks: 5)
    @journal.write(held: [{ kind: 'key', code: KEY_H }], owner:)
    @x.keys_down << KEY_H
    status, result, = @machine.run_json('input', 'key', 'a', '--no-capture', '--token', @token)

    assert_equal 3, status
    assert_equal 'PRECONDITION_FAILED', result[:error][:code]
    assert_empty @x.fake_inputs

    _, reported, = @machine.run_json('status')

    assert_equal 'in_progress', reported[:data][:input][:state]
  end

  def test_a_damaged_journal_is_cleared_with_nothing_to_release
    FileUtils.mkdir_p(File.dirname(journal_path))
    File.write(journal_path, 'not json')
    status, result, = @machine.run_json('input', 'release', '--token', @token)

    assert_equal 0, status
    assert_equal 0, result[:data][:released]
    assert_nil @journal.read
  end

  def test_a_journal_of_the_wrong_shape_counts_as_damaged
    FileUtils.mkdir_p(File.dirname(journal_path))
    File.write(journal_path, '[1]')

    assert_equal({ damaged: true }, @journal.read)
  end

  def test_the_journal_is_gone_after_a_normal_key
    @machine.run_json('input', 'key', 'a', '--hold-ms', '5', '--no-capture', '--token', @token)

    assert_nil @journal.read
  end

  def test_the_journal_is_private
    leave_held({ kind: 'key', code: KEY_H })

    assert_equal 0o600, File.stat(journal_path).mode & 0o777
  end

  private

  def journal_path = File.join(Cdctl::Paths.new(@machine.env).input_dir, Cdctl::Input::Journal::FILE)
end

# Real processes against the fake server, since what is under test is what happens when one dies.
class SentinelTest < Minitest::Test
  KEY_H = FakeXServer.keycode('h'.ord)
  ITEM = { kind: 'key', code: KEY_H }.freeze
  WAIT = 5.0

  def setup
    @x = FakeXServer.new
    @directory = Dir.mktmpdir('cdctl-sentinel-')
    @journal = Cdctl::Input::Journal.new(@directory)
    @connection = @x.opener.call(@x.display)
  end

  def teardown
    @connection.close
    @x.stop
    FileUtils.remove_entry(@directory)
  end

  def opener = -> { @x.opener.call(@x.display) }

  def start = Cdctl::Input::Sentinel.start(open_connection: opener, journal: @journal)

  def press
    @connection.fake_key(KEY_H, down: true)
    @journal.write(held: [ITEM])
  end

  def wait_until(what)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT
    sleep(0.005) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    flunk(what) unless yield
  end

  def test_when_the_owner_dies_it_releases_and_clears_the_journal
    ready_read, ready_write = IO.pipe
    owner = fork do
      ready_read.close
      sentinel = start
      sentinel.arm([ITEM], 30)
      press
      ready_write.write('x')
      ready_write.close
      sleep
    end
    ready_write.close
    ready_read.read(1)

    assert_equal [KEY_H], @x.keys_down
    Process.kill('KILL', owner)
    Process.wait(owner)
    wait_until('the sentinel never released') { @x.keys_down.empty? }
    wait_until('the journal stayed') { @journal.read.nil? }
  end

  def test_when_told_done_it_leaves_alone_whatever_is_down
    sentinel = start
    sentinel.arm([ITEM], 30)
    press
    sentinel.finish

    assert_equal [KEY_H], @x.keys_down
    assert_raises(Errno::ECHILD) { Process.wait(sentinel.pid, Process::WNOHANG) }
  end

  def test_disarmed_it_has_nothing_to_release
    ready_read, ready_write = IO.pipe
    owner = fork do
      ready_read.close
      sentinel = start
      sentinel.arm([ITEM], 30)
      sentinel.disarm
      ready_write.write('x')
      ready_write.close
      sleep
    end
    ready_write.close
    ready_read.read(1)
    @x.keys_down << KEY_H
    Process.kill('KILL', owner)
    Process.wait(owner)
    sleep(0.2)

    assert_equal [KEY_H], @x.keys_down
  end

  def test_a_hold_past_its_deadline_is_released_and_reported
    sentinel = start
    sentinel.arm([ITEM], -Cdctl::Input::Sentinel::MARGIN + 0.05)
    press
    wait_until('the deadline never fired') { @x.keys_down.empty? }
    seen = nil
    wait_until('it never reported') { (seen ||= sentinel.trouble) == :expired }
    sentinel.finish
  end

  def test_its_death_is_seen
    sentinel = start
    Process.kill('KILL', sentinel.pid)
    wait_until('its death went unseen') { sentinel.trouble == :gone }

    assert_equal :gone, sentinel.trouble
    assert_raises(Cdctl::Input::Sentinel::Unavailable) { sentinel.arm([ITEM], 1) }
    sentinel.finish
  end

  def test_it_ignores_the_signals_that_stop_a_program
    sentinel = start
    %w[INT TERM HUP QUIT].each { Process.kill(it, sentinel.pid) }
    sleep(0.1)

    assert sentinel.arm([ITEM], 30)
    sentinel.finish
  end

  def test_it_runs_in_a_session_of_its_own
    sentinel = start

    refute_equal Process.getsid, Process.getsid(sentinel.pid)
    sentinel.finish
  end

  # A caller reading the output waits for every holder of the pipe, and this process outlives the
  # program. The program here stays alive, with its own stdout elsewhere, so only the sentinel could
  # be keeping the pipe open.
  def test_it_keeps_no_hold_on_the_callers_output
    reader, writer = IO.pipe
    ready_read, ready_write = IO.pipe
    program = fork do
      reader.close
      ready_read.close
      $stdout.reopen(writer)
      writer.close
      start
      File.open(File::NULL, 'w') { $stdout.reopen(it) }
      ready_write.write('x')
      ready_write.close
      sleep
    end
    writer.close
    ready_write.close
    ready_read.read(1)

    assert reader.wait_readable(WAIT)
    assert_nil reader.read_nonblock(1, exception: false)
  ensure
    Process.kill('KILL', program)
    Process.wait(program)
  end

  def test_an_x_server_it_cannot_reach_means_no_sentinel
    unreachable = -> { raise Cdctl::X11::ConnectError, 'no' }

    assert_raises(Cdctl::Input::Sentinel::Unavailable) do
      Cdctl::Input::Sentinel.start(open_connection: unreachable, journal: @journal)
    end
  end
end

# The sentinel's logic without its process, so each decision can be watched step by step.
class SentinelWatchTest < Minitest::Test
  KEY_H = FakeXServer.keycode('h'.ord)
  BUTTON = 3
  WAIT = 5.0

  def setup
    @x = FakeXServer.new
    @directory = Dir.mktmpdir('cdctl-watch-')
    @journal = Cdctl::Input::Journal.new(@directory)
    @connection = @x.opener.call(@x.display)
    to_read, @to_write = IO.pipe
    @from_read, from_write = IO.pipe
    watch = Cdctl::Input::Sentinel::Watch.new(to_read, from_write, @connection, @journal)
    @thread = Thread.new { watch.run }
    line
  end

  def teardown
    @thread.kill
    @connection.close
    @x.stop
    FileUtils.remove_entry(@directory)
  end

  def line = (@from_read.gets if @from_read.wait_readable(WAIT))&.chomp

  def tell(text)
    @to_write.puts(text)
    @to_write.flush
  end

  def arm(items, seconds: 30)
    tell(JSON.generate(held: items, seconds:))

    assert_equal 'armed', line
  end

  def press_key
    @connection.fake_key(KEY_H, down: true)
    @journal.write(held: [{ kind: 'key', code: KEY_H }])
  end

  def test_when_the_pipe_closes_it_releases_keys_and_buttons_and_clears_the_journal
    arm([{ kind: 'key', code: KEY_H }, { kind: 'button', code: BUTTON }])
    press_key
    @connection.fake_button(BUTTON, down: true)
    @to_write.close

    assert @thread.join(WAIT)
    assert_empty @x.keys_down
    assert_empty @x.buttons_down
    assert_nil @journal.read
  end

  def test_when_told_done_it_touches_nothing
    arm([{ kind: 'key', code: KEY_H }])
    press_key
    tell('done')

    assert @thread.join(WAIT)
    assert_equal [KEY_H], @x.keys_down
    refute_nil @journal.read
  end

  def test_with_nothing_held_a_closed_pipe_releases_nothing
    arm([{ kind: 'key', code: KEY_H }])
    arm([], seconds: nil)
    @connection.fake_key(KEY_H, down: true)
    @to_write.close

    assert @thread.join(WAIT)
    assert_equal [KEY_H], @x.keys_down
  end

  def test_a_deadline_releases_says_so_and_keeps_watching
    arm([{ kind: 'key', code: KEY_H }], seconds: 0.02)
    press_key

    assert_equal 'expired', line
    assert_empty @x.keys_down
    assert_nil @journal.read
    assert_predicate @thread, :alive?
    arm([], seconds: nil)
  end

  def test_an_answer_nobody_reads_does_not_stop_it
    @from_read.close
    tell(JSON.generate(held: [{ kind: 'key', code: KEY_H }], seconds: 30))
    sleep(0.02)
    @connection.fake_key(KEY_H, down: true)
    @to_write.close

    assert @thread.join(WAIT)
    assert_empty @x.keys_down
  end
end

class ConnectionRefusalTest < Minitest::Test
  def setup
    @x = FakeXServer.new
    @connection = @x.opener.call(@x.display)
  end

  def teardown
    @connection.close
    @x.stop
  end

  def test_a_refused_send_raises_and_the_stream_stays_usable
    @x.refuse_fake_input = true

    assert_raises(Cdctl::X11::RequestError) { @connection.fake_key(40, down: true) }
    @x.refuse_fake_input = false

    assert_kind_of Integer, @connection.input_focus
    assert_empty @connection.keys_held
  end

  def test_keys_and_buttons_are_read_back
    @connection.fake_key(40, down: true)
    @connection.fake_button(2, down: true)

    assert_equal [40], @connection.keys_held
    assert @connection.button_down?(2)
    refute @connection.button_down?(1)
    refute_equal 0, @connection.pointer.buttons_down
  end

  def test_motion_moves_the_pointer
    @connection.fake_motion(300, -5)

    assert_equal [300, -5], @connection.pointer.to_h.values_at(:x, :y)
  end

  def test_the_keymap_names_keycodes
    assert_equal FakeXServer.keycode(0xFF1B), @connection.keycode_for(0xFF1B)
    assert_nil @connection.keycode_for(0xFFFF)
  end

  def test_no_event_is_an_answer_in_time
    @connection.xi2_version
    @connection.select_raw_events
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_nil @connection.next_raw_event(0.02)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end

  def test_an_event_says_its_kind_and_its_device_and_nothing_else
    @connection.xi2_version
    @connection.select_raw_events
    @x.input_from_a_person(:key_press)
    event = @connection.next_raw_event(1)

    assert_equal :key_press, event.kind
    assert_equal FakeXServer::REAL_KEYBOARD, event.source
    assert_equal %i[kind source], event.to_h.keys
  end
end
