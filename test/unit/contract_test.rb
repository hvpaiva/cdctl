# frozen_string_literal: true

require 'test_helper'

# What any caller may rely on, whatever the machine looks like.
class ContractTest < Minitest::Test
  include SchemaAssertions

  COMMANDS = {
    'status' => %w[status], 'doctor' => %w[doctor], 'capabilities' => %w[capabilities],
    'schema' => %w[schema status], 'observe' => %w[observe], 'screenshot' => %w[screenshot],
    'version' => %w[version], 'help' => %w[help status]
  }.freeze
  READ_ONLY_TOPICS = %w[version clients activewindow monitors layers locked].freeze

  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def assert_all_results_valid(machine)
    COMMANDS.each do |name, argv|
      _, result, = machine.run_json(*argv)

      assert_valid(name, result)
    end
  end

  def test_results_match_their_schemas_on_a_bare_machine
    assert_all_results_valid(@machine)
  end

  def test_results_match_their_schemas_with_steam_only
    @machine.install_game(@machine.steam_root)

    assert_all_results_valid(@machine)
  end

  def test_results_match_their_schemas_with_a_running_game
    @machine.full_game(width: 800, height: 600, options: OptionFiles.sample)

    assert_all_results_valid(@machine)
  end

  def test_results_match_their_schemas_with_a_compositor_driver
    @machine.full_game(width: 800, height: 600, options: OptionFiles.sample(viewport: '640 480'))
    @machine.hyprland(width: 800, height: 600)

    assert_all_results_valid(@machine)
  end

  def test_an_observation_check_matches_its_schema
    @machine.full_game(width: 800, height: 600)
    id = @machine.run_json('observe')[1][:data][:observation_id]

    assert_valid('observation.check', @machine.run_json('observation', 'check', id)[1])
  end

  def test_the_envelope_answers_the_questions_a_caller_has
    @machine.full_game
    _, result, = @machine.run_json('status', '--request-id', 'abc-1')

    assert_equal '1', result[:schema_version]
    assert_equal 'abc-1', result[:request_id]
    assert_equal 'status', result[:command]
    assert result[:ok]
    assert_operator result[:duration_ms], :>=, 0
    refute result[:changed]
    assert_empty result[:actions]
    assert_equal 4242, result[:target][:pid]
  end

  def test_stdout_holds_only_the_document
    @machine.full_game
    _, out, err = @machine.run('status', '--json')

    assert_equal 1, out.lines.size
    assert JSON.parse(out)
    assert_empty err
  end

  def read_only_program?(argv)
    case argv
    in ['hyprctl', '-i', _, '-j', topic] then READ_ONLY_TOPICS.include?(topic)
    in ['hyprctl', 'instances', '-j'] | ['grim', *, '-'] then true
    else false
    end
  end

  # `changed` and `actions` only say what a command claims, so this watches what it really sends.
  def test_observing_sends_nothing_that_could_change_the_game
    @machine.full_game(width: 100, height: 100)
    @machine.hyprland(width: 100, height: 100)
    @machine.shell.on('grim', stdout: "P6\n1 1\n255\n\x00\x00\x00".b)
    %w[status doctor capabilities observe screenshot].each do |command|
      _, result, = @machine.run_json(command)

      refute result[:changed], command
      assert_empty result[:actions], command
    end
    @machine.run_json('screenshot', '--backend', 'grim')
    server = @machine.x_server

    assert_includes server.request_names, 'GetImage'
    assert_empty server.requests_that_could_change_something
    assert_includes(@machine.shell.calls.map(&:first), 'grim')
    assert_empty(@machine.shell.calls.reject { read_only_program?(it) })
  end

  def test_nothing_about_another_window_reaches_any_output
    @machine.full_game(width: 100, height: 100)
    @machine.hyprland(active_pid: 99, width: 100, height: 100)
    [%w[status], %w[doctor], %w[capabilities], %w[observe], %w[screenshot --backend grim]].each do |argv|
      [@machine.run(*argv), @machine.run(*argv, '--json')].each do |_, out, err|
        refute_includes out + err, Machine::ANOTHER_WINDOW_TITLE, argv.join(' ')
        refute_includes out + err, 'other.program', argv.join(' ')
      end
    end
  end

  def test_the_game_is_reported_as_active_or_not_and_nothing_more
    @machine.full_game
    @machine.hyprland(active_pid: 99)
    compositor = @machine.run_json('status')[1][:data][:compositor]

    refute compositor[:game_active]
    refute compositor.key?(:active_window)
    assert_equal 'Crimson Desert', compositor[:game_client][:title]
  end

  def test_help_for_an_observation_command_is_a_document_too
    [%w[status --help], %w[help status], %w[observation check --help]].each do |argv|
      status, out, = @machine.run(*argv, '--json')

      assert_equal 0, status, argv.join(' ')
      assert_valid('help', JSON.parse(out))
    end
  end

  def test_a_bare_group_is_a_usage_document_under_json
    status, out, = @machine.run('observation', '--request-id', 'abc-1', '--json')
    result = JSON.parse(out)

    assert_equal 2, status
    assert_equal 'USAGE', result.dig('error', 'code')
    assert_equal 'abc-1', result['request_id']
  end

  def test_exit_status_follows_the_error_category
    { %w[status --nope] => 2, %w[observe] => 3, %w[screenshot] => 3, %w[status] => 0 }.each do |argv, expected|
      assert_equal expected, @machine.run(*argv, '--json').first, argv.join(' ')
    end
  end

  def test_every_failure_is_a_document_under_json
    [%w[status --nope], %w[observe], %w[observation check nope], %w[status --request-id bad/id]].each do |argv|
      _, out, = @machine.run(*argv, '--json')
      result = JSON.parse(out)

      refute result['ok'], argv.join(' ')
      assert_includes Cdctl::ErrorCodes::CODES.keys, result.dig('error', 'code'), argv.join(' ')
    end
  end

  def test_a_failure_carries_a_useful_next_step
    _, result, = @machine.run_json('observe')

    refute_empty result[:next_steps]
    assert_match(/Start the game/, result[:next_steps].first)
  end

  def test_text_mode_prints_errors_on_stderr_only
    status, out, err = @machine.run('observe')

    assert_equal 3, status
    assert_empty out
    assert_match(/error: the game is not running \[GAME_NOT_RUNNING\]/, err)
    assert_match(/next: Start the game/, err)
  end

  def test_hostile_text_from_the_machine_cannot_drive_the_terminal
    @machine.full_game
    @machine.hyprland(layers: { '3' => [{ 'namespace' => "auth\e[2Jx", 'w' => 9, 'h' => 9 }] })
    _, out, = @machine.run('status')
    _, _, err = @machine.run('observe')

    assert_match(/present: auth\^\[\[2Jx/, out)
    refute_includes out, "\e"
    assert_match(/auth\^\[\[2Jx/, err)
    refute_includes err, "\e"
  end

  def test_json_keeps_the_text_as_it_came_and_escapes_it
    @machine.full_game
    @machine.x_server.set_property(Machine::GAME_WINDOW, 'WM_NAME', "evil\e[2Jtitle")
    _, out, = @machine.run('status', '--json')

    refute_includes out, "\e"
    assert_equal "evil\e[2Jtitle", JSON.parse(out).dig('data', 'window', 'title')
  end

  def test_invalid_utf8_from_a_window_cannot_break_the_json
    @machine.full_game
    @machine.x_server.set_property(Machine::GAME_WINDOW, 'WM_NAME', "bad\xFFname".b)
    status, out, = @machine.run('status', '--json')

    assert_equal 0, status
    assert JSON.parse(out)
  end

  def test_help_needs_no_machine_at_all
    ['status --help', 'screenshot --help', 'observation check --help'].each do |line|
      status, out, = @machine.run(*line.split)

      assert_equal 0, status, line
      refute_empty out, line
    end
  end

  def test_a_closed_stdout_does_not_change_the_answer
    @machine.full_game
    out = Object.new
    def out.puts(*) = raise(Errno::EPIPE)
    def out.print(*) = raise(Errno::EPIPE)
    context = Cdctl::CLI::Context.new(out:, err: StringIO.new, env: @machine.env)

    assert_equal 0, Cdctl.run(%w[status --json], context:, runtime_factory: ->(_, _) { @machine.runtime })
  end
end

class CapabilitiesTest < Minitest::Test
  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  GRIM_PIXEL = "P6\n1 1\n255\n\x00\x00\x00".b

  def capability(id)
    @machine.run_json('capabilities')[1][:data][:capabilities].find { it[:id] == id }
  end

  def grim_calls = @machine.shell.calls.select { it.first == 'grim' }

  def test_grim_installed_but_failing_is_not_a_capability
    @machine.hyprland
    @machine.shell.on('grim', status: 1, stderr: 'compositor does not support screencopy')
    found = capability('capture.grim')

    assert_equal 'unavailable', found[:state]
    assert_match(/screencopy/, found[:reason])
  end

  def test_grim_is_available_only_after_returning_a_pixel
    @machine.hyprland
    @machine.shell.on('grim', stdout: GRIM_PIXEL)

    assert_equal 'available', capability('capture.grim')[:state]
  end

  def test_garbage_from_grim_is_not_a_capability
    @machine.hyprland
    @machine.shell.on('grim', stdout: 'hello')

    assert_equal 'unavailable', capability('capture.grim')[:state]
  end

  # A capture refuses grim without a driver, so a working grim alone would promise what it refuses.
  def test_grim_is_no_capability_without_a_driver_to_guard_it
    @machine.shell.on('grim', stdout: GRIM_PIXEL)
    found = capability('capture.grim')

    assert_equal 'unavailable', found[:state]
    assert_match(/compositor driver/, found[:reason])
    assert_empty grim_calls
  end

  def test_grim_is_not_tried_while_a_dialog_is_present
    @machine.full_game
    @machine.hyprland(layers: { '3' => [{ 'namespace' => 'auth', 'w' => 9, 'h' => 9 }] })
    @machine.shell.on('grim', stdout: GRIM_PIXEL)

    assert_equal 'unverified', capability('capture.grim')[:state]
    assert_empty grim_calls
  end

  def test_x11_capture_is_proven_by_getting_a_pixel
    assert_equal 'unavailable', capability('observe.window')[:state]
    @machine.full_game

    assert_equal 'available', capability('capture.x11_window')[:state]
    assert_includes @machine.x_server.request_names, 'GetImage'
    @machine.x_server.refuse_images = true
    found = capability('capture.x11_window')

    assert_equal 'unavailable', found[:state]
    assert_match(/BadMatch/, found[:reason])
  end

  # The server answers for any depth, and the capture would then refuse what cdctl cannot decode.
  def test_a_pixel_format_that_cannot_be_read_is_no_capability
    @machine.full_game
    @machine.x_server.windows.fetch(Machine::GAME_WINDOW).depth = 30
    found = capability('capture.x11_window')

    assert_equal 'unavailable', found[:state]
    assert_match(/pixel format/, found[:reason])
  end

  def test_with_nothing_to_try_them_on_they_are_unverified
    @machine.start_x

    %w[observe.process observe.window observe.resolution capture.x11_window].each do |id|
      assert_equal 'unverified', capability(id)[:state], id
    end
  end

  def test_with_the_game_running_they_are_proven
    @machine.full_game

    %w[observe.process observe.window observe.resolution capture.x11_window].each do |id|
      assert_equal 'available', capability(id)[:state], id
    end
  end

  def test_planned_work_is_listed_as_such
    %w[game.launch game.quit menu.open settings.set].each do |id|
      assert_equal 'not_implemented', capability(id)[:state], id
    end
  end

  def test_the_hud_depends_on_a_mod
    assert_equal 'mod_dependent', capability('hud.radar')[:state]
  end

  def test_other_platforms_answer_unsupported
    @machine.platform = Cdctl::Platform::WINDOWS

    %w[observe.process observe.window observe.resolution capture.x11_window capture.grim].each do |id|
      assert_equal 'unsupported', capability(id)[:state], id
    end
  end

  def test_only_tried_setups_claim_to_be_tested_with_the_game
    @machine.full_game
    other = @machine.run_json('capabilities')[1][:data][:environment]

    assert_equal 'not_tested_with_the_game', other[:validation]
    @machine.hyprland

    assert_equal 'tested_with_the_game', @machine.run_json('capabilities')[1][:data][:environment][:validation]
  end

  def test_a_nested_game_is_not_the_setup_that_was_tested
    @machine.full_game
    @machine.hyprland
    @machine.add_process(50, comm: 'gamescope-wl', argv: ['gamescope'])
    @machine.run_game(parent: 50)

    assert_equal 'not_tested_with_the_game', @machine.run_json('capabilities')[1][:data][:environment][:validation]
  end

  def test_every_error_code_and_exit_status_is_published
    data = @machine.run_json('capabilities')[1][:data]

    assert_equal Cdctl::ErrorCodes::CODES.keys.sort, data[:error_codes].map { it[:code] }.sort
    assert_equal %w[0 1 130 2 3 4].sort, data[:exit_statuses].keys.map(&:to_s).sort
  end
end

class ForeignPlatformTest < Minitest::Test
  def setup
    @machine = Machine.new
    @machine.platform = Cdctl::Platform::WINDOWS
    @machine.env.merge!('ProgramFiles(x86)' => File.join(@machine.home, 'pf'),
                        'LOCALAPPDATA' => File.join(@machine.home, 'lad'))
    FileUtils.mkdir_p(File.join(@machine.home, 'pf/Steam/steamapps'))
    @machine.install_game(File.join(@machine.home, 'pf/Steam'), compat: false)
  end

  def teardown = @machine.destroy

  def test_discovery_works_and_the_rest_says_unsupported
    status, result, = @machine.run_json('status')

    assert_equal 0, status
    assert_equal 'found', result[:data][:installation][:state]
    assert_equal 'unsupported', result[:data][:game][:state]
  end

  def test_observing_answers_unsupported_platform
    status, result, = @machine.run_json('observe')

    assert_equal 4, status
    assert_equal 'UNSUPPORTED_PLATFORM', result[:error][:code]
  end

  def test_nothing_tries_to_start_a_linux_program
    @machine.run_json('capabilities')

    assert_empty @machine.shell.calls
  end

  def test_no_external_program_is_started_for_x11
    _, result, = @machine.run_json('status')

    assert_equal 'unavailable', result[:data][:x11][:status]
  end
end

class DoctorTest < Minitest::Test
  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def check(result, id) = result[:data][:checks].find { it[:id] == id }

  def test_a_bare_machine_fails_and_says_how_to_fix_it
    status, result, = @machine.run_json('doctor')

    assert_equal 3, status
    refute result[:data][:healthy]
    assert_equal 'fail', check(result, 'steam')[:status]
    assert_match(/CDCTL_STEAM_ROOT/, check(result, 'steam')[:remedy])
    assert_includes result[:next_steps].join, 'CDCTL_STEAM_ROOT'
  end

  def test_a_closed_game_is_healthy
    @machine.start_x
    @machine.install_game(@machine.steam_root)
    status, result, = @machine.run_json('doctor')

    assert_equal 0, status
    assert result[:data][:healthy]
    assert_equal 'info', check(result, 'game_process')[:status]
    assert_equal 'skip', check(result, 'game_window')[:status]
  end

  def test_a_running_game_is_tried_for_real
    @machine.full_game
    _, result, = @machine.run_json('doctor')

    assert_equal 'ok', check(result, 'capture')[:status]
    assert_equal 'ok', check(result, 'game_window')[:status]
  end

  def test_a_capture_that_would_be_refused_is_not_called_healthy
    @machine.full_game
    @machine.x_server.windows.fetch(Machine::GAME_WINDOW).depth = 30
    _, result, = @machine.run_json('doctor')

    assert_equal 'warn', check(result, 'capture')[:status]
    assert_match(/pixel format/, check(result, 'capture')[:detail])
  end

  def test_a_dialog_that_cannot_be_ruled_out_is_not_called_none
    @machine.full_game
    @machine.hyprland(active_pid: 99)
    _, result, = @machine.run_json('doctor')

    assert_equal 'info', check(result, 'system_dialogs')[:status]
    assert_match(/another window/, check(result, 'system_dialogs')[:detail])
  end

  def test_an_unwritable_state_directory_fails
    blocked = File.join(@machine.home, 'blocked')
    File.write(blocked, 'a file, not a directory')
    @machine.env['CDCTL_STATE_HOME'] = File.join(blocked, 'state')
    @machine.install_game(@machine.steam_root)
    status, result, = @machine.run_json('doctor')

    assert_equal 3, status
    assert_equal 'fail', check(result, 'state_directory')[:status]
  end

  def test_text_mode_lists_the_checks_even_when_failing
    status, out, err = @machine.run('doctor')

    assert_equal 3, status
    assert_match(/fail\s+steam/, out)
    assert_match(/fix: Set CDCTL_STEAM_ROOT/, out)
    assert_match(/check\(s\) failed/, err)
  end
end
