# frozen_string_literal: true

require 'test_helper'

# People read the text form, and it reads the same data as the JSON form.
class HumanOutputTest < Minitest::Test
  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def test_status_says_everything_on_a_full_machine
    @machine.full_game(width: 800, height: 600, options: OptionFiles.sample(viewport: '640 480'))
    @machine.hyprland(width: 800, height: 600)
    status, out, err = @machine.run('status')

    assert_equal 0, status
    assert_empty err
    assert_match(/Build\s+2\.04\.05 \(Steam build 111, english, Proton 9\.0-1\)/, out)
    assert_match(/Game\s+running as PID 4242/, out)
    assert_match(/Window\s+0x5000001 800x600\+0\+0 focused/, out)
    assert_match(/Compositor\s+hyprland v1\.2\.3, game on OUT-1/, out)
    assert_match(/Stored resolution\s+640x480 \[option_file\]/, out)
    assert_match(/Presentation\s+stretched \[option_file\+x11, inferred\]/, out)
  end

  def test_status_says_what_is_missing_on_a_bare_machine
    _, out, = @machine.run('status')

    assert_match(/Installation\s+not found/, out)
    assert_match(/Game\s+not running/, out)
    assert_match(/X11\s+unavailable: no DISPLAY/, out)
    assert_match(/System dialogs\s+cannot see them/, out)
    assert_match(/Not verified: .*system_dialogs/, out)
  end

  def test_status_names_a_present_dialog_and_a_nested_game
    @machine.full_game
    @machine.hyprland(layers: { '3' => [{ 'namespace' => 'auth', 'w' => 9, 'h' => 9 }] })
    @machine.add_process(50, comm: 'gamescope-wl', argv: ['gamescope'])
    @machine.run_game(parent: 50)
    _, out, = @machine.run('status')

    assert_match(/System dialogs\s+present: auth/, out)
    assert_match(/inside a nested compositor/, out)
  end

  def test_a_field_the_file_omits_is_not_given_a_default
    @machine.full_game(options: %(<EngineOptionSave><OptionInt Name="_other" _value="1"/></EngineOptionSave>))
    _, out, = @machine.run('status')

    assert_match(/Stored resolution\s+not in the file/, out)
    assert_match(/Render scale\s+not in the file/, out)
    assert_match(/HUD scale\s+not in the file/, out)
    refute_match(/default/, out)
  end

  def test_a_closed_game_is_on_no_monitor
    @machine.start_x
    @machine.hyprland
    _, out, = @machine.run('status')

    assert_match(/Compositor\s+hyprland v1\.2\.3$/, out)
    refute_match(/game on/, out)
  end

  def test_status_says_when_a_dialog_cannot_be_ruled_out
    @machine.full_game
    @machine.hyprland(active_pid: 99)
    _, out, = @machine.run('status')

    assert_match(/System dialogs\s+not verified: another window is active/, out)
    assert_match(/Not verified: .*system_dialogs/, out)
  end

  def test_an_unknown_state_says_why
    @machine.full_game
    FileUtils.remove_entry(@machine.proc_root)
    _, out, = @machine.run('status')

    assert_match(/Game\s+unknown: cannot list processes/, out)
  end

  def test_a_lost_connection_is_not_a_missing_window
    @machine.full_game
    @machine.x_server.hang_up_after = 5
    status, out, = @machine.run('status')

    assert_equal 0, status
    assert_match(/X11\s+unavailable: the X server closed the connection/, out)
    assert_match(/Window\s+unknown: the X server closed the connection/, out)
  end

  def test_a_timeout_is_an_error_in_text_too
    @machine.full_game
    @machine.x_server.client_timeout = 0.05
    @machine.x_server.silent = true
    status, out, err = @machine.run('status')

    assert_equal 1, status
    assert_empty out
    assert_match(/did not answer.*\[TIMEOUT\]/, err)
  end

  def test_observe_names_the_observation_and_the_file
    @machine.full_game(width: 100, height: 100)
    _, out, = @machine.run('observe')

    assert_match(/Observation\s+obs-[0-9a-f]{16}/, out)
    assert_match(/Capture\s+.*\.png/, out)
    assert_match(/Screen\s+unknown/, out)
  end

  def test_screenshot_and_check_print_their_results
    @machine.full_game(width: 100, height: 100)
    _, shot, = @machine.run('screenshot')
    id = @machine.run_json('observe')[1][:data][:observation_id]
    _, checked, = @machine.run('observation', 'check', id)

    assert_match(/File\s+.*\.png/, shot)
    assert_match(/Size\s+100x100/, shot)
    assert_match(/Valid\s+true/, checked)
  end

  def test_capabilities_lists_states_and_reasons
    _, out, = @machine.run('capabilities')

    assert_match(/linux, compositor unknown, not tested with the game/, out)
    assert_match(/game\.launch\s+not_implemented/, out)
    assert_match(/hud\.radar\s+mod_dependent/, out)
    assert_match(/no game window to try|no DISPLAY/, out)
  end

  def test_schema_prints_a_schema_and_a_list
    _, one, = @machine.run('schema', 'doctor')
    _, list, = @machine.run('schema')

    assert_equal 'cdctl doctor result', JSON.parse(one)['title']
    assert_match(/Available\s+capabilities/, list)
    assert_match(/Planned\s+game\.continue/, list)
  end

  def test_doctor_prints_each_check_when_healthy
    @machine.full_game(options: OptionFiles.sample)
    @machine.hyprland
    status, out, = @machine.run('doctor')

    assert_equal 0, status
    assert_match(/ok\s+capture\s+X11 returned an image/, out)
    assert_match(/ok\s+compositor\s+hyprland v1\.2\.3/, out)
    assert_match(/ok\s+system_dialogs\s+none over the game/, out)
  end

  def test_color_is_applied_only_when_asked
    @machine.env['NO_COLOR'] = '1'
    _, plain, = @machine.run('status')
    _, painted, = @machine.run('status', '--color')

    refute_includes plain, "\e["
    assert_includes painted, "\e["
  end

  def test_a_bare_group_prints_its_summary_as_a_usage_error
    status, out, err = @machine.run('observation')

    assert_equal 2, status
    assert_empty out
    assert_match(/Usage: cdctl observation/, err)
  end
end
