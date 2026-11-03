# frozen_string_literal: true

require 'test_helper'

module DrivingHelpers
  KEY_PRESS = 2
  BUTTON_PRESS = 4

  def start(screen: 'world', preset: 'standard')
    @machine = Machine.new
    @ui = @machine.game_with_ui(screen:, preset:)
    @x = @machine.x_server
    @token = @machine.lease_token
  end

  def command(*)
    @machine.run_json(*, '--token', @token)
  end

  def presses(keysym) = @x.fake_inputs.count { it.first(2) == [KEY_PRESS, FakeXServer.keycode(keysym)] }

  def clicks = @x.fake_inputs.count { it.first == BUTTON_PRESS }

  def keys_sent = @x.fake_inputs.count { it.first == KEY_PRESS }

  def assert_nothing_sent = assert_empty(@x.fake_inputs)

  def assert_all_released
    assert_empty @x.keys_down
    assert_empty @x.buttons_down
  end

  def sent_names(result) = result[:actions].reject { it[:type] == 'move' }.map { it[:key] || it[:point] }
end

class MenuOpenTest < Minitest::Test
  include SchemaAssertions
  include DrivingHelpers

  def teardown = @machine.destroy

  def test_it_opens_the_map_from_the_world_and_proves_it
    start
    status, result, = command('menu', 'open', 'map')

    assert_equal 0, status
    assert result[:changed]
    assert_equal %w[world menu.map], [result[:before][:screen], result[:after][:screen]]
    assert_equal %w[visual_anchors menu.map], result[:verification].values_at(:method, :expected)
    assert_equal 'menu.map', @ui.screen
    refute_includes result[:not_verified], 'game.screen'
    assert_valid 'menu.open', result
    assert_all_released
  end

  # The exit criterion: M on an open map would close it.
  def test_opening_a_map_already_open_sends_nothing
    start(screen: 'menu.map')
    status, result, = command('menu', 'open', 'map')

    assert_equal 0, status
    refute result[:changed]
    assert_empty result[:actions]
    assert_nothing_sent
    assert_equal 'menu.map', @ui.screen
  end

  def test_a_stalled_game_gets_one_key_and_patience
    start
    @ui.stall = 1.0
    status, result, = command('menu', 'open', 'map')

    assert_equal 0, status
    assert_equal 1, presses('m'.ord)
    assert_equal 'menu.map', result[:after][:screen]
  end

  def test_a_game_that_never_reacts_is_not_pressed_again
    start
    @ui.deaf = true
    status, result, = command('menu', 'open', 'map', '--timeout', '1')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 1, presses('m'.ord)
    assert_includes result[:error][:message], 'menu.map'
    assert_includes result[:next_steps].join, 'Do not repeat'
    assert_equal 1, result[:actions].size
    assert_nil result[:changed]
  end

  # A frame in the middle of a transition can match by chance, and it is gone by the next look.
  def test_one_frame_that_matches_is_not_an_arrival
    start
    @ui.deaf = true
    @x.on_fake_input = lambda do |type, _|
      next unless type == KEY_PRESS

      @ui.show('menu.map')
      @x.after_image = lambda do |_window|
        @ui.show('world')
        @x.after_image = nil
      end
    end
    status, result, = command('menu', 'open', 'map', '--timeout', '1')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 1, presses('m'.ord)
  end

  # The game can stall for longer than a caller waits, so its key may still be on its way.
  def test_after_no_answer_the_next_command_does_not_send_again_at_once
    start
    @ui.deaf = true
    command('menu', 'open', 'map', '--timeout', '1')
    status, result, = command('menu', 'open', 'map', '--timeout', '1')

    assert_equal 3, status
    assert_equal 'PRECONDITION_FAILED', result[:error][:code]
    assert_operator result[:error][:details][:retry_after_seconds], :>, 0
    assert_equal 1, presses('m'.ord)
  end

  def test_the_screen_having_moved_ends_that_wait
    start
    @ui.deaf = true
    command('menu', 'open', 'map', '--timeout', '1')
    @ui.deaf = false
    @ui.show('menu.inventory')
    status, result, = command('menu', 'open', 'journal')

    assert_equal 0, status
    assert_equal 'menu.journal', result[:after][:screen]
  end

  def test_that_wait_does_not_last_forever
    start
    @ui.deaf = true
    command('menu', 'open', 'map', '--timeout', '1')
    @ui.deaf = false
    path = File.join(Cdctl::Paths.new(@machine.env).input_dir, Cdctl::Driving::Unanswered::FILE)
    record = JSON.parse(File.read(path))
    File.write(path, JSON.generate(record.merge('at' => (Time.now - 60).iso8601(3))))

    assert_equal 0, command('menu', 'open', 'map').first
    refute_path_exists path
  end

  def test_a_screen_that_will_not_read_answers_that_the_target_changed
    start
    @x.on_fake_input = lambda do |type, _|
      @x.refuse_images = true if type == 3
    end
    status, result, = command('menu', 'open', 'map', '--timeout', '1')

    assert_equal 3, status
    assert_equal 'TARGET_CHANGED', result[:error][:code]
    assert_equal 1, result[:actions].size
    assert_nil result[:changed]
  ensure
    @x.refuse_images = false
  end

  def test_tabs_are_reached_by_clicking_them
    start(screen: 'menu.map')
    status, result, = command('menu', 'open', 'inventory')

    assert_equal 0, status
    assert_equal ['menu.tab.inventory'], sent_names(result)
    assert_equal 0, keys_sent
    assert_equal 1, clicks
  end

  def test_settings_are_reached_step_by_step_from_the_world
    start
    status, result, = command('menu', 'open', 'settings.input')

    assert_equal 0, status
    assert_equal %w[m menu.tab.others others.settings settings.tab.input], sent_names(result)
    assert_equal 'settings.input', @ui.screen
    assert_equal 4, result[:data][:steps]
  end

  def test_a_click_lands_at_the_scaled_point
    start(screen: 'menu.map')
    command('menu', 'open', 'journal')
    x, y = FakeGameUi::SHIPPED.point('menu.tab.journal', FakeGameUi::HEIGHT)
    motion = @x.fake_inputs.find { it.first == 6 }

    assert_equal [x, y], motion.last(2)
  end

  # A tab says which menu is open and nothing about what its list holds, so the entry has to be seen.
  def test_an_entry_that_is_not_there_is_not_clicked
    start(screen: 'menu.others')
    @ui.hidden = ['others.settings.label']
    @ui.redraw
    status, result, = command('menu', 'open', 'settings.video', '--timeout', '1')

    assert_equal 3, status
    assert_equal 'UNKNOWN_SCREEN', result[:error][:code]
    assert_includes result[:error][:message], 'its input was not sent'
    assert_nothing_sent
  end

  # Measured on the real game: a list draws well after its tab is recognized, and a click that comes
  # too early does nothing. So the click waits for the list, and then a moment more.
  def test_a_list_that_draws_after_its_tab_is_waited_for
    start(screen: 'menu.map')
    @ui.list_lag = 1.3
    status, result, = command('menu', 'open', 'settings.video', '--timeout', '3')

    assert_equal 0, status
    assert_equal %w[menu.tab.others others.settings], sent_names(result)
    assert_equal 'settings.video', @ui.screen
  end

  # A frame in the middle of a transition can match by chance, so it takes two looks in a row.
  def test_an_entry_seen_in_one_frame_only_is_not_clicked
    start(screen: 'menu.others')
    looks = 0
    original = Cdctl::Driving::Navigator.instance_method(:seen?)
    Cdctl::Driving::Navigator.define_method(:seen?) { |_anchors| (looks += 1) == 2 }
    status, result, = command('menu', 'open', 'settings.video', '--timeout', '1')

    assert_equal 3, status
    assert_equal 'UNKNOWN_SCREEN', result[:error][:code]
    assert_nothing_sent
  ensure
    Cdctl::Driving::Navigator.define_method(:seen?, original)
  end

  def test_losing_the_focus_while_waiting_for_a_list_sends_nothing
    start(screen: 'menu.others')
    @ui.hidden = ['others.settings.label']
    @ui.redraw
    Thread.new do
      sleep(0.3)
      @x.focus = 0
    end
    status, result, = command('menu', 'open', 'settings.video', '--timeout', '3')

    assert_equal 3, status
    assert_equal 'FOCUS_LOST', result[:error][:code]
    assert_nothing_sent
  end

  # An entry that is missing says so soon, whatever --timeout allows for a slow menu.
  def test_a_long_timeout_does_not_lengthen_the_wait_for_an_entry
    start(screen: 'menu.others')
    @ui.hidden = ['others.settings.label']
    @ui.redraw
    original = Cdctl::Driving::Navigator::STEP_TIMEOUT
    Cdctl::Driving::Navigator.send(:remove_const, :STEP_TIMEOUT)
    Cdctl::Driving::Navigator.const_set(:STEP_TIMEOUT, 0.3)
    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, result, = command('menu', 'open', 'settings.video', '--timeout', '5')

    assert_equal 3, status
    assert_equal 'UNKNOWN_SCREEN', result[:error][:code]
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - began, :<, 3
  ensure
    Cdctl::Driving::Navigator.send(:remove_const, :STEP_TIMEOUT)
    Cdctl::Driving::Navigator.const_set(:STEP_TIMEOUT, original)
  end

  def test_a_release_left_by_an_earlier_command_counts_as_a_change
    start(screen: 'menu.map')
    journal = Cdctl::Input::Journal.new(Cdctl::Paths.new(@machine.env).input_dir)
    journal.write(held: [{ kind: 'key', code: 40 }], owner: { pid: 999_999, start_ticks: 1 })
    status, result, = command('menu', 'open', 'map')

    assert_equal 0, status
    assert result[:changed]
    assert_equal(['release'], result[:actions].map { it[:type] })
    assert_equal 0, result[:data][:steps]
  end

  def test_a_capture_that_cannot_be_taken_does_not_undo_the_answer
    start
    @x.on_fake_input = lambda do |type, _|
      next unless type == 3

      @ui.show('menu.map')
      @machine.hyprland(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT, layers: {
                          '3' => [{ 'namespace' => 'polkit-agent', 'x' => 0, 'y' => 0, 'w' => 50, 'h' => 30 }]
                        })
    end
    original = Cdctl::Driving::Navigator.instance_method(:wait_for)
    machine = @machine
    Cdctl::Driving::Navigator.define_method(:wait_for) do |names, timeout: 20|
      original.bind_call(self, names, timeout:)
    end
    status, result, = command('menu', 'open', 'map')

    assert_equal 0, status, machine.class.name
    assert_empty result[:artifacts]
    assert_nil result[:verification][:screenshot]
    assert_includes result[:not_verified], 'game.active_resolution'
    refute_includes result[:not_verified], 'game.screen'
  ensure
    Cdctl::Driving::Navigator.define_method(:wait_for, original)
  end

  def test_from_the_title_settings_can_be_reached
    start(screen: 'title')
    status, result, = command('menu', 'open', 'settings.gameplay')

    assert_equal 0, status
    assert_equal 'o', sent_names(result).first
    assert_equal 'settings.gameplay', @ui.screen
  end

  def test_from_the_title_the_game_menu_cannot_be_reached
    start(screen: 'title')
    status, result, = command('menu', 'open', 'map')

    assert_equal 3, status
    assert_equal 'PRECONDITION_FAILED', result[:error][:code]
    assert_includes result[:next_steps].join, 'game continue'
    assert_nothing_sent
  end

  def test_a_screen_nobody_knows_sends_nothing
    start
    @ui.show('loading')
    status, result, = command('menu', 'open', 'map')

    assert_equal 3, status
    assert_equal 'UNKNOWN_SCREEN', result[:error][:code]
    assert_nothing_sent
  end

  def test_a_game_with_no_profile_sends_nothing
    @machine = Machine.new
    @machine.playable_game
    @x = @machine.x_server
    @token = @machine.lease_token
    status, result, = command('menu', 'open', 'map')

    assert_equal 4, status
    assert_equal 'UNSUPPORTED_BUILD', result[:error][:code]
    assert_includes result[:next_steps].join, 'cdctl input'
    assert_nothing_sent
  end

  def test_a_preset_the_profile_was_not_measured_with_sends_nothing
    start
    @machine.write_options(FakeGameUi.options_text('standard').sub('_select="A"', '_select="B"'), modified_at: Time.now)
    status, result, = command('menu', 'open', 'map')

    assert_equal 4, status
    assert_equal 'UNSUPPORTED_BUILD', result[:error][:code]
    assert_nothing_sent
  end

  def test_both_measured_presets_work
    start(preset: 'classic')

    assert_equal 0, command('menu', 'open', 'map').first
  end

  def test_no_token_sends_nothing
    start
    status, result, = @machine.run_json('menu', 'open', 'map')

    assert_equal 3, status
    assert_equal 'LEASE_BUSY', result[:error][:code]
    assert_nothing_sent
  end

  def test_a_lost_focus_during_the_wait_stops_it
    start
    @x.on_fake_input = ->(type, _) { @x.focus = 0 if type == 3 }
    status, result, = command('menu', 'open', 'map')

    assert_equal 3, status
    assert_equal 'FOCUS_LOST', result[:error][:code]
    assert_equal 1, result[:actions].size
    assert_all_released
  end

  def test_a_person_during_the_wait_stops_it
    start
    @ui.deaf = true
    @x.on_fake_input = ->(type, _) { @x.input_from_a_person(:key_press) if type == 3 }
    status, result, = command('menu', 'open', 'map')

    assert_equal 3, status
    assert_equal 'USER_INTERFERENCE', result[:error][:code]
  end

  def test_the_command_line_is_checked
    start

    assert_equal 2, command('menu', 'open', 'nowhere').first
    assert_equal 2, command('menu', 'open', 'map', '--timeout', '0').first
    assert_equal 2, command('menu', 'open', 'map', '--timeout', '301').first
    assert_nothing_sent
  end

  def test_human_output
    start
    status, out, = @machine.run('menu', 'open', 'map', '--token', @token)

    assert_equal 0, status
    assert_match(/Before\s+world/, out)
    assert_match(/After\s+menu\.map/, out)
    assert_match(/Steps\s+1/, out)
  end
end

class MenuBackTest < Minitest::Test
  include SchemaAssertions
  include DrivingHelpers

  def teardown = @machine.destroy

  def test_a_menu_closes_to_the_world
    start(screen: 'menu.map')
    status, result, = command('menu', 'back')

    assert_equal 0, status
    assert_equal 'world', result[:after][:screen]
    assert_equal 1, presses(0xFF1B)
    assert_valid 'menu.back', result
  end

  def test_settings_opened_from_the_game_return_to_its_menu
    start(screen: 'menu.others')
    command('menu', 'open', 'settings.video')
    status, result, = command('menu', 'back')

    assert_equal 0, status
    assert_equal 'menu.others', result[:after][:screen]
  end

  def test_settings_opened_from_the_title_return_to_the_title
    start(screen: 'title')
    command('menu', 'open', 'settings.video')
    status, result, = command('menu', 'back')

    assert_equal 0, status
    assert_equal 'title', result[:after][:screen]
  end

  def test_in_the_world_there_is_nothing_to_go_back_from
    start
    status, result, = command('menu', 'back')

    assert_equal 0, status
    refute result[:changed]
    assert_nothing_sent
  end

  def test_on_the_title_escape_would_mean_leaving_so_nothing_is_sent
    start(screen: 'title')
    status, result, = command('menu', 'back')

    assert_equal 0, status
    refute result[:changed]
    assert_nothing_sent
  end

  def test_escape_is_not_sent_to_a_screen_nobody_knows
    start
    @ui.show('loading')

    assert_equal 'UNKNOWN_SCREEN', command('menu', 'back')[1][:error][:code]
    assert_nothing_sent
  end
end

class GameLaunchTest < Minitest::Test
  include SchemaAssertions

  def setup
    @machine = Machine.new
    @machine.start_x(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
    @machine.install_game(@machine.steam_root, build: FakeGameUi::BUILD, language: FakeGameUi::LANGUAGE,
                                               options: FakeGameUi.options_text('standard'))
    @machine.hyprland(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT, client_pid: 4242)
    @token = @machine.lease_token
  end

  def teardown = @machine.destroy

  # What Steam does when asked: the game appears, on the title screen.
  def steam_starts_the_game(screen: 'title')
    @machine.shell.on('steam', '-applaunch') do
      @machine.run_game
      @machine.game_window(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
      FakeGameUi.new(@machine, screen:)
      ''
    end
  end

  def launch(*extra) = @machine.run_json('game', 'launch', '--token', @token, *extra)

  def test_it_starts_through_steam_and_waits_for_the_title
    steam_starts_the_game
    status, result, = launch

    assert_equal 0, status
    assert result[:changed]
    assert result[:data][:started]
    assert_equal 'title', result[:after][:screen]
    assert_equal 'visual_anchors', result[:verification][:method]
    assert_includes @machine.shell.calls, ['steam', '-applaunch', Machine::APP_ID.to_s]
    assert_valid 'game.launch', result
  end

  def test_a_running_game_is_not_started_again
    @machine.run_game
    @machine.game_window(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
    status, result, = launch

    assert_equal 0, status
    refute result[:changed]
    refute result[:data][:started]
    refute_includes @machine.shell.calls, ['steam', '-applaunch', Machine::APP_ID.to_s]
  end

  def test_no_lease_starts_nothing
    status, result, = @machine.run_json('game', 'launch', '--token', "cdl-9-#{'0' * 32}")

    assert_equal 3, status
    assert_equal 'LEASE_LOST', result[:error][:code]
    refute_includes @machine.shell.calls.map(&:first), 'steam'
  end

  def test_waiting_for_the_process_only
    steam_starts_the_game
    status, result, = launch('--wait', 'none')

    assert_equal 0, status
    assert_equal 'process', result[:verification][:method]
  end

  def test_waiting_for_the_window_only
    steam_starts_the_game(screen: 'loading')
    status, result, = launch('--wait', 'window')

    assert_equal 0, status
    assert_equal 'process', result[:verification][:method]
  end

  def test_a_title_that_never_comes_is_a_timeout_and_not_a_success
    steam_starts_the_game(screen: 'loading')
    status, result, = launch('--timeout', '1')

    assert_equal 1, status
    assert_equal 'TIMEOUT', result[:error][:code]
    assert result[:changed]
    assert_equal 'launch', result[:actions].first[:type]
  end

  def test_steam_refusing_says_so
    @machine.shell.on('steam', '-applaunch', status: 1)
    status, result, = launch

    assert_equal 3, status
    assert_includes result[:error][:message], 'exit status 1'
    refute result[:changed]
  end

  def test_a_launch_already_on_its_way_is_not_started_again
    @machine.add_process(800, comm: 'reaper', argv: ['reaper', 'SteamLaunch', "AppId=#{Machine::APP_ID}"])
    status, result, = launch('--timeout', '1')

    assert_equal 1, status
    assert_equal 'TIMEOUT', result[:error][:code]
    refute result[:changed]
    assert_empty result[:actions]
    refute_includes @machine.shell.calls.map(&:first), 'steam'
  end

  # A game that has just closed leaves Steam's wrapper behind for a few seconds, exactly like one that
  # is starting. When it goes and nothing takes its place, there is a game to start.
  def test_a_launch_right_after_a_close_starts_once_the_wrapper_is_gone
    steam_starts_the_game
    @machine.add_process(800, comm: 'reaper', argv: ['reaper', 'SteamLaunch', "AppId=#{Machine::APP_ID}"])
    Thread.new do
      sleep(0.5)
      FileUtils.rm_rf(File.join(@machine.proc_root, '800'))
    end
    status, result, = launch

    assert_equal 0, status, result[:error]
    assert result[:changed]
    assert result[:data][:started]
    assert_equal(1, @machine.shell.calls.count { it.first == 'steam' })
  end

  def test_several_processes_start_nothing_more
    @machine.run_game
    @machine.run_game(pid: 4243)
    status, result, = launch

    assert_equal 3, status
    assert_equal 'TARGET_AMBIGUOUS', result[:error][:code]
    refute_includes @machine.shell.calls.map(&:first), 'steam'
  end

  def test_a_signal_during_the_wait_still_says_the_game_was_started
    @machine.shell.on('steam', '-applaunch', stdout: '')
    Thread.new do
      sleep(0.3)
      Process.kill('TERM', Process.pid)
    end
    status, result, = launch

    assert_equal 130, status
    assert_equal 'INTERRUPTED', result[:error][:code]
    assert result[:changed]
    assert_equal 'launch', result[:actions].first[:type]
  end

  def test_a_launch_is_recorded_even_before_the_window_exists
    @machine.shell.on('steam', '-applaunch') do
      @machine.run_game
      ''
    end

    assert_equal 0, launch('--wait', 'none').first
    @machine.game_window(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
    _, result, = @machine.run_json('status')

    assert_equal 'known', result[:data][:resolution][:launch_display_mode][:status]
  end

  def test_with_no_steam_program_it_asks_the_desktop
    @machine.shell.on('xdg-open') do
      @machine.run_game
      @machine.game_window(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
      FakeGameUi.new(@machine, screen: 'title')
      ''
    end
    status, = launch

    assert_equal 0, status
    assert_includes @machine.shell.calls, ['xdg-open', "steam://rungameid/#{Machine::APP_ID}"]
  end

  # With Steam closed this command stays running as Steam, which is no failure and must not be stopped.
  def test_a_steam_that_stays_running_is_not_a_failure
    @machine.shell.on('steam', '-applaunch', status: nil) do
      @machine.run_game
      @machine.game_window(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
      FakeGameUi.new(@machine, screen: 'title')
      ''
    end

    assert_equal 0, launch.first
  end

  def test_the_display_at_launch_makes_the_image_known
    steam_starts_the_game
    launch
    _, result, = @machine.run_json('status')
    resolution = result[:data][:resolution]

    assert_equal 'known', resolution[:launch_display_mode][:status]
    assert_equal FakeGameUi::WIDTH, resolution[:launch_display_mode][:value][:width]
    assert_equal 'native', resolution[:presentation][:value][:mode]
    assert_equal 'inferred', resolution[:presentation][:confidence]
  end

  def test_a_game_cdctl_did_not_launch_stays_unknown
    @machine.run_game
    @machine.game_window(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
    _, result, = @machine.run_json('status')
    resolution = result[:data][:resolution]

    assert_equal 'unknown', resolution[:launch_display_mode][:status]
    assert_equal 'unknown', resolution[:presentation][:status]
  end

  def test_the_command_line_is_checked
    assert_equal 2, launch('--timeout', 'soon').first
    assert_equal 2, launch('--wait', 'tomorrow').first
  end

  def test_no_game_installed_is_a_clear_answer
    machine = Machine.new
    machine.start_x
    token = machine.lease_token
    status, result, = machine.run_json('game', 'launch', '--token', token)

    assert_equal 3, status
    assert_equal 'GAME_NOT_INSTALLED', result[:error][:code]
  ensure
    machine.destroy
  end
end

class GameContinueTest < Minitest::Test
  include SchemaAssertions
  include DrivingHelpers

  def teardown = @machine.destroy

  def test_it_presses_the_entry_and_waits_for_the_world
    start(screen: 'title')
    @ui.stall = 0.6
    status, result, = command('game', 'continue')

    assert_equal 0, status
    assert_equal 1, presses('e'.ord)
    assert_equal 0, presses('z'.ord), 'z starts a new game'
    assert_equal 'world', result[:after][:screen]
    assert_equal 'title', result[:before][:screen]
    assert_valid 'game.continue', result
  end

  def test_already_in_the_world_nothing_is_sent
    start
    status, result, = command('game', 'continue')

    assert_equal 0, status
    refute result[:changed]
    assert_nothing_sent
  end

  def test_from_anywhere_else_nothing_is_sent
    start(screen: 'menu.map')
    status, result, = command('game', 'continue')

    assert_equal 3, status
    assert_equal 'PRECONDITION_FAILED', result[:error][:code]
    assert_nothing_sent
  end

  def test_a_world_that_never_comes_is_a_failure
    start(screen: 'title')
    @ui.deaf = true
    status, result, = command('game', 'continue', '--timeout', '1')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 1, presses('e'.ord)
  end

  def test_a_title_without_the_entry_sends_nothing
    start(screen: 'title')
    @ui.instance_variable_get(:@frames).clear
    @ui.define_singleton_method(:visible_anchors) { %w[title.copyright title.settings_label] }
    @ui.redraw
    status, result, = command('game', 'continue', '--timeout', '1')

    assert_equal 3, status
    assert_equal 'UNKNOWN_SCREEN', result[:error][:code]
    assert_nothing_sent
  end
end

class GameQuitTest < Minitest::Test
  include SchemaAssertions
  include DrivingHelpers

  def teardown = @machine.destroy

  def test_from_the_world_it_goes_through_the_menu_and_the_dialog
    start
    status, result, = command('game', 'quit', '--graceful')

    assert_equal 0, status
    assert_equal %w[m menu.tab.others others.quit space], sent_names(result)
    assert_equal({ process: 'closed' }, result[:after])
    assert_equal 'process', result[:verification][:method]
    assert_equal 1, presses(0x20)
    assert_valid 'game.quit', result
  end

  def test_the_confirmation_is_long_enough_for_the_game_to_take_it
    start(screen: 'menu.others')
    _, result, = command('game', 'quit')

    assert_operator result[:actions].last[:held_ms], :>=, 1000
  end

  def test_from_the_title_it_holds_the_exit_key
    start(screen: 'title')
    status, result, = command('game', 'quit')

    assert_equal 0, status
    assert_equal ['Escape'], sent_names(result)
    assert_operator result[:actions].last[:held_ms], :>=, 1000
  end

  def test_a_closed_game_sends_nothing
    start
    FileUtils.rm_rf(File.join(@machine.proc_root, '4242'))
    status, result, = command('game', 'quit')

    assert_equal 0, status
    refute result[:changed]
    refute result[:data][:sent]
    assert_nothing_sent
  end

  def test_a_game_still_starting_is_not_called_closed
    start
    FileUtils.rm_rf(File.join(@machine.proc_root, '4242'))
    @machine.add_process(800, comm: 'reaper', argv: ['reaper', 'SteamLaunch', "AppId=#{Machine::APP_ID}"])
    status, result, = command('game', 'quit')

    assert_equal 3, status
    assert_equal 'PRECONDITION_FAILED', result[:error][:code]
    assert_nothing_sent
  end

  # The game can end while the confirming key is still down, which looks like a lost target.
  def test_a_game_that_ends_during_the_confirmation_has_done_what_was_asked
    start(screen: 'menu.others')
    @ui.exit_on_press = true
    status, result, = command('game', 'quit')

    assert_equal 0, status
    assert_equal({ process: 'closed' }, result[:after])
    assert_all_released
  end

  def test_a_game_that_ends_during_the_hold_on_the_title_has_done_what_was_asked
    start(screen: 'title')
    @ui.exit_on_press = true
    status, = command('game', 'quit')

    assert_equal 0, status
    assert_all_released
  end

  def test_an_exit_entry_that_is_not_there_is_not_clicked
    start(screen: 'menu.others')
    @ui.hidden = ['others.quit.label']
    @ui.redraw
    status, result, = command('game', 'quit', '--timeout', '1')

    assert_equal 3, status
    assert_equal 'UNKNOWN_SCREEN', result[:error][:code]
    assert_equal 0, clicks
  end

  def test_a_game_that_does_not_end_is_a_timeout_and_nothing_is_killed
    start(screen: 'menu.others')
    @ui.define_singleton_method(:exit_game) { nil }
    status, result, = command('game', 'quit', '--timeout', '1')

    assert_equal 1, status
    assert_equal 'TIMEOUT', result[:error][:code]
    assert_includes result[:next_steps].join, 'Nothing was killed'
    assert_path_exists File.join(@machine.proc_root, '4242')
  end

  def test_no_dialog_means_no_confirmation
    start(screen: 'menu.others')
    @ui.deaf = true
    status, result, = command('game', 'quit', '--timeout', '1')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 0, presses(0x20)
  end
end

class SettingsCommandsTest < Minitest::Test
  include SchemaAssertions
  include DrivingHelpers

  def teardown = @machine.destroy

  def set(*) = command('settings', 'set', *)

  def test_list_shows_values_and_what_can_change
    start
    status, result, = @machine.run_json('settings', 'list')
    settings = result[:data][:settings].to_h { [it[:name], it] }

    assert_equal 0, status
    assert_equal 'standard', settings['keyboard_mouse_preset'][:value]
    assert settings['keyboard_mouse_preset'][:editable]
    refute settings['gamepad_preset'][:editable]
    assert_equal '90', settings['hud_scale'][:raw]
    assert_valid 'settings.list', result
  end

  def test_list_filters_by_section
    start
    _, result, = @machine.run_json('settings', 'list', '--section', 'input')

    assert_equal(%w[keyboard_mouse_preset gamepad_preset], result[:data][:settings].map { it[:name] })
  end

  def test_get_names_a_value_the_file_omits
    start(preset: 'classic')
    status, result, = @machine.run_json('settings', 'get', 'keyboard_mouse_preset')

    assert_equal 0, status
    assert_equal 'classic', result[:data][:value]
    assert_nil result[:data][:raw]
    assert_includes result[:not_verified], 'settings.value_in_the_running_game'
    assert_valid 'settings.get', result
  end

  def test_an_unknown_setting_is_a_usage_error
    start

    assert_equal 2, @machine.run_json('settings', 'get', 'volume').first
  end

  def test_settings_need_no_running_game
    start
    FileUtils.rm_rf(File.join(@machine.proc_root, '4242'))

    assert_equal 0, @machine.run_json('settings', 'list').first
  end

  def test_a_build_with_no_profile_says_so
    @machine = Machine.new
    @machine.full_game(options: FakeGameUi.options_text('standard'))

    assert_equal 'UNSUPPORTED_BUILD', @machine.run_json('settings', 'list')[1][:error][:code]
  end

  def test_a_file_that_cannot_be_read_is_said_so
    start
    @machine.write_options('nothing useful')

    assert_equal 3, @machine.run_json('settings', 'list').first
  end

  def test_plan_says_what_would_change_and_sends_nothing
    start
    status, result, = @machine.run_json('settings', 'plan', 'keyboard_mouse_preset=classic')

    assert_equal 0, status
    assert_equal 'standard', result[:data][:from]
    assert_equal({ element: '_keyboardMousePresetOptionType', was: 'A', will_be: nil }, result[:data][:file_change])
    assert_includes result[:data][:restore], 'keyboard_mouse_preset standard'
    assert result[:data][:needed]
    assert_valid 'settings.plan', result
    assert_nothing_sent
  end

  def test_plan_refuses_what_no_profile_saw_work
    start

    assert_equal 'UNSUPPORTED_BUILD', @machine.run_json('settings', 'plan', 'gamepad_preset=standard')[1][:error][:code]
    assert_equal 'UNSUPPORTED_BUILD',
                 @machine.run_json('settings', 'plan', 'keyboard_mouse_preset=expert')[1][:error][:code]
    assert_equal 2, @machine.run_json('settings', 'plan', 'keyboard_mouse_preset').first
  end

  def test_without_apply_nothing_is_sent
    start
    status, result, = set('keyboard_mouse_preset', 'classic')

    assert_equal 0, status
    refute result[:data][:applied]
    refute result[:changed]
    assert_nothing_sent
    assert_equal 'standard', @ui.preset
  end

  # The exit criterion: only the preset changes, the real diff equals the plan, and it comes back.
  def test_only_that_setting_changes
    start
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')
    changes = result[:data][:real_changes]

    assert_equal 0, status
    assert result[:changed]
    assert_equal 'classic', @ui.preset
    assert_equal 1, changes.size
    assert changes.first[:setting].end_with?('_keyboardMousePresetOptionType')
    assert_equal 'option_file', result[:verification][:method]
    assert_includes result[:next_steps].join, 'keyboard_mouse_preset standard'
    assert_valid 'settings.set', result
  end

  def test_the_change_comes_back_the_way_it_says
    start
    set('keyboard_mouse_preset', 'classic', '--apply')
    status, back, = set('keyboard_mouse_preset', 'standard', '--apply')

    assert_equal 0, status
    assert_equal 'standard', @ui.preset
    assert_equal 'A', back[:data][:real_changes].first[:now][:_select]
    assert_all_released
  end

  def test_the_dialog_is_recognized_before_it_is_confirmed
    start
    _, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal %w[m menu.tab.others others.settings settings.tab.input settings.input.keyboard.previous space space],
                 sent_names(result)
  end

  # The second key confirms a dialog. Without the dialog it would mean something else.
  def test_a_dialog_that_does_not_open_gets_no_confirmation
    start(screen: 'settings.input')
    @ui.define_singleton_method(:apply_confirm) { nil }
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply', '--timeout', '1')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 1, presses(0x20)
    assert_equal 'standard', @ui.preset
  end

  def test_the_right_element_with_the_wrong_value_is_a_failure
    start
    @ui.on_apply = lambda do
      @machine.write_options(FakeGameUi.options_text('standard').sub('_keyboardMousePresetOptionType" _select="A"',
                                                                     '_keyboardMousePresetOptionType" _select="B"'),
                             modified_at: Time.now + 1)
    end
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 1, result[:data][:real_changes].size
  end

  # The game was seen to take a moment over its writes, and a second one can differ from the first.
  def test_a_second_write_is_what_gets_compared
    start
    @ui.on_apply = lambda do
      Thread.new do
        sleep(0.35)
        @machine.write_options(FakeGameUi.options_text('classic').sub('_value="90"', '_value="120"'),
                               modified_at: Time.now + 2)
      end
    end
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 2, result[:data][:real_changes].size
  end

  def test_a_file_caught_in_the_middle_of_a_write_is_not_the_answer_yet
    start
    @ui.on_apply = lambda do
      @machine.write_options('', modified_at: Time.now + 1)
      Thread.new do
        sleep(0.4)
        @machine.write_options(FakeGameUi.options_text('classic'), modified_at: Time.now + 2)
      end
    end
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 0, status
    assert_equal 1, result[:data][:real_changes].size
  end

  def test_a_change_applied_and_proved_says_so_even_if_something_goes_wrong_next
    start
    @ui.on_apply = lambda do
      Thread.new do
        sleep(0.5)
        @x.focus = 0
      end
    end
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 3, status
    assert_equal 'FOCUS_LOST', result[:error][:code]
    assert result[:data][:applied]
    assert_equal 1, result[:data][:real_changes].size
    assert_includes result[:next_steps].join, 'keyboard_mouse_preset standard'
  end

  # The key was seen by the game or it was not, and neither answer would be honest.
  def test_a_failure_during_the_confirmation_says_nothing_is_known
    start
    @ui.on_apply = -> { @x.focus = 0 }
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 3, status
    assert_equal 'FOCUS_LOST', result[:error][:code]
    assert_nil result[:data][:applied]
    assert result[:data][:confirmation_sent]
    assert_includes result[:next_steps].join, 'settings get'
  end

  def test_a_row_left_changed_and_not_applied_is_said_to_be
    start(screen: 'settings.input')
    @x.on_fake_input = lambda do |type, detail|
      @ui.send(:react, type, detail)
      @x.focus = 0 if type == 5
    end
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 3, status
    assert_equal 'FOCUS_LOST', result[:error][:code]
    assert result[:data][:row_left_pending]
    refute result[:data][:applied]
    assert_includes result[:next_steps].join, 'nothing applied'
    assert_equal 'standard', @ui.preset
  end

  # A scrolled list puts another row at the same point, with the same value on it.
  def test_a_row_that_is_not_there_is_not_clicked
    start(screen: 'settings.input')
    @ui.hidden = ['settings.input.keyboard.row']
    @ui.redraw
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply', '--timeout', '1')

    assert_equal 3, status
    assert_equal 'UNKNOWN_SCREEN', result[:error][:code]
    assert_equal 0, clicks
  end

  def test_a_row_that_draws_late_is_waited_for
    start(screen: 'settings.input')
    @ui.hidden = ['settings.input.keyboard.row']
    @ui.redraw
    Thread.new do
      sleep(0.4)
      @ui.hidden = []
      @ui.redraw
    end
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 0, status, result[:error]
    assert_equal 'classic', @ui.preset
  end

  def test_a_value_already_set_sends_nothing
    start
    status, result, = set('keyboard_mouse_preset', 'standard', '--apply')

    assert_equal 0, status
    refute result[:changed]
    assert_nothing_sent
  end

  def test_a_menu_that_disagrees_with_the_file_changes_nothing
    start(screen: 'settings.input')
    @machine.write_options(FakeGameUi.options_text('classic'), modified_at: Time.now - 10)
    status, result, = set('keyboard_mouse_preset', 'standard', '--apply')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_includes result[:error][:message], 'does not show'
    assert_equal 0, clicks
  end

  def test_another_setting_changing_too_is_a_failure_with_the_way_back
    start
    @ui.on_apply = lambda do
      text = FakeGameUi.options_text('classic').sub('_value="90"', '_value="120"')
      @machine.write_options(text, modified_at: Time.now + 1)
    end
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_equal 2, result[:data][:real_changes].size
    assert_includes result[:next_steps].join, 'keyboard_mouse_preset standard'
  end

  def test_a_file_that_never_changes_is_a_failure_after_a_wait
    start
    @ui.on_apply = -> { @machine.write_options(FakeGameUi.options_text('standard'), modified_at: Machine::LONG_AGO) }
    original = Cdctl::Commands::SettingsSet::FILE_TIMEOUT
    Cdctl::Commands::SettingsSet.send(:remove_const, :FILE_TIMEOUT)
    Cdctl::Commands::SettingsSet.const_set(:FILE_TIMEOUT, 0.3)
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 1, status
    assert_includes result[:error][:message], 'did not change'
  ensure
    Cdctl::Commands::SettingsSet.send(:remove_const, :FILE_TIMEOUT)
    Cdctl::Commands::SettingsSet.const_set(:FILE_TIMEOUT, original)
  end

  def test_a_row_that_does_not_change_is_a_failure
    start(screen: 'settings.input')
    @ui.define_singleton_method(:choose) { |_value| nil }
    original = Cdctl::Commands::SettingsSet::VALUE_TIMEOUT
    Cdctl::Commands::SettingsSet.send(:remove_const, :VALUE_TIMEOUT)
    Cdctl::Commands::SettingsSet.const_set(:VALUE_TIMEOUT, 0.3)
    status, result, = set('keyboard_mouse_preset', 'classic', '--apply')

    assert_equal 1, status
    assert_includes result[:error][:message], 'did not change'
    assert_equal 0, presses(0x20)
  ensure
    Cdctl::Commands::SettingsSet.send(:remove_const, :VALUE_TIMEOUT)
    Cdctl::Commands::SettingsSet.const_set(:VALUE_TIMEOUT, original)
  end

  def test_human_output
    start
    status, out, = @machine.run('settings', 'list', '--section', 'input')

    assert_equal 0, status
    assert_match(/keyboard_mouse_preset\s+standard \(editable\)/, out)

    status, out, = @machine.run('settings', 'get', 'keyboard_mouse_preset')

    assert_equal 0, status
    assert_match(/Options\s+standard, classic/, out)

    status, out, = @machine.run('settings', 'plan', 'keyboard_mouse_preset=classic')

    assert_equal 0, status
    assert_match(/Undo\s+cdctl settings set keyboard_mouse_preset standard/, out)
  end
end

class InputExpectScreenTest < Minitest::Test
  include DrivingHelpers

  def teardown = @machine.destroy

  def test_the_expected_screen_is_the_verification
    start
    status, result, = command('input', 'key', 'm', '--expect-screen', 'menu.map')

    assert_equal 0, status
    assert result[:changed]
    assert_equal 'visual_anchors', result[:verification][:method]
    assert_equal 'menu.map', result[:after][:screen]
    assert_equal 'world', result[:before][:screen]
    refute_includes result[:not_verified], 'input.result'
    refute_includes result[:not_verified], 'game.screen'
    assert_empty result[:next_steps]
  end

  def test_a_screen_that_does_not_come_is_a_failure
    start
    @ui.deaf = true
    original = Cdctl::Driving::Navigator::STEP_TIMEOUT
    Cdctl::Driving::Navigator.send(:remove_const, :STEP_TIMEOUT)
    Cdctl::Driving::Navigator.const_set(:STEP_TIMEOUT, 0.4)
    status, result, = command('input', 'key', 'm', '--expect-screen', 'menu.map')

    assert_equal 1, status
    assert_equal 'VERIFY_FAILED', result[:error][:code]
    assert_nil result[:changed]
  ensure
    Cdctl::Driving::Navigator.send(:remove_const, :STEP_TIMEOUT)
    Cdctl::Driving::Navigator.const_set(:STEP_TIMEOUT, original)
  end

  def test_a_screen_the_profile_does_not_know_costs_no_key
    start
    status, result, = command('input', 'key', 'h', '--expect-screen', 'moon')

    assert_equal 4, status
    assert_equal 'UNSUPPORTED_BUILD', result[:error][:code]
    assert_nothing_sent
  end

  # The screen it started on proves nothing: a game in a stall shows that one for a while yet.
  def test_expecting_the_screen_already_there_proves_nothing
    start
    @ui.deaf = true
    status, result, = command('input', 'key', 'm', '--expect-screen', 'world')

    assert_equal 0, status
    assert_nil result[:changed]
    assert_equal 'caller_required', result[:verification][:method]
    assert_includes result[:not_verified], 'input.result'
    assert_includes result[:not_verified], 'game.screen'
    refute_empty result[:next_steps]
  end

  def test_with_no_profile_it_cannot_expect_anything
    @machine = Machine.new
    @machine.playable_game
    @x = @machine.x_server
    @token = @machine.lease_token

    assert_equal 4, command('input', 'key', 'h', '--expect-screen', 'world').first
    assert_nothing_sent
  end
end
