# frozen_string_literal: true

require 'test_helper'

# A source that fails becomes a reason in the report. None of these may end in INTERNAL_ERROR, which
# would throw away everything else that was found.
class BrokenSourcesTest < Minitest::Test
  OBSERVATION = 'obs-0000000000000000'

  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def status = @machine.run_json('status')

  def state_directory(name)
    File.join(@machine.home, '.local/state/cdctl', name).tap { FileUtils.mkdir_p(it) }
  end

  def capability(id)
    @machine.run_json('capabilities')[1][:data][:capabilities].find { it[:id] == id }
  end

  def rewrite_manifest
    path = File.join(@machine.steam_root, "steamapps/appmanifest_#{Machine::APP_ID}.acf")
    File.write(path, yield(File.read(path)))
  end

  def test_a_damaged_ledger_is_replaced
    @machine.full_game
    File.write(File.join(state_directory('sessions'), 'abcdef01-4242-5000.json'), '[]')
    code, result, = status

    assert_equal 0, code
    assert_equal 'found', result[:data][:window][:state]
    assert_match(/first observation/, result[:data][:resolution][:coherence][:reason])
  end

  def test_a_library_file_of_the_wrong_shape_is_a_problem_in_the_report
    File.write(File.join(@machine.steam_root, 'steamapps/libraryfolders.vdf'), %("libraryfolders" "x"\n))
    code, result, = status

    assert_equal 0, code
    assert_match(/not a block/, result[:data][:installation][:problems].first)
  end

  def test_a_library_whose_path_is_a_block_is_skipped
    File.write(File.join(@machine.steam_root, 'steamapps/libraryfolders.vdf'),
               %("libraryfolders"\n{\n"0"\n{\n"path"\n{\n}\n}\n}\n))

    assert_equal 0, status.first
  end

  def test_a_manifest_field_holding_a_block_is_no_value
    @machine.install_game(@machine.steam_root)
    rewrite_manifest { it.sub(/"StateFlags"\s+"\d+"/, %("StateFlags"\n{\n}\n)) }
    code, result, = status

    assert_equal 0, code
    assert_equal 'found', result[:data][:installation][:state]
    refute result[:data][:installation][:fully_installed]
  end

  def test_an_install_directory_holding_a_block_is_a_problem_in_the_report
    @machine.install_game(@machine.steam_root)
    rewrite_manifest { it.sub(/"installdir"\s+"[^"]+"/, %("installdir"\n{\n}\n)) }
    code, result, = status

    assert_equal 0, code
    assert_match(/invalid installdir/, result[:data][:installation][:problems].first)
  end

  def test_processes_that_cannot_be_listed_are_not_a_closed_game
    @machine.full_game
    FileUtils.remove_entry(@machine.proc_root)
    code, result, = status

    assert_equal 0, code
    assert_equal 'unknown', result[:data][:game][:state]
    assert_match(/cannot list processes/, result[:data][:game][:reason])
    assert_equal 'PRECONDITION_FAILED', @machine.run_json('observe')[1][:error][:code]
    assert_equal 'unavailable', capability('observe.process')[:state]
    doctor = @machine.run_json('doctor')[1][:data][:checks].find { it[:id] == 'game_process' }

    assert_equal 'fail', doctor[:status]
  end

  def test_empty_configuration_keys_mean_the_defaults
    path = File.join(@machine.home, 'config.yaml')
    File.write(path, "steam_root:\nignored_overlay_layers:\nevidence_keep:\n")
    @machine.env['CDCTL_CONFIG'] = path
    @machine.full_game(width: 100, height: 100)

    assert_equal 0, status.first
    assert_equal 0, @machine.run_json('screenshot').first
  end

  def test_an_output_path_that_cannot_be_expanded_is_a_usage_error
    @machine.full_game(width: 100, height: 100)
    code, result, = @machine.run_json('screenshot', '--output', '~no-such-user-here/shot.png')

    assert_equal 2, code
    assert_equal 'USAGE', result[:error][:code]
  end

  def test_a_damaged_observation_is_not_found
    path = File.join(state_directory('observations'), "#{OBSERVATION}.json")
    ['[]', '{}', '{"state":{},"observed_at":"soon"}', 'nonsense'].each do |text|
      File.write(path, text)
      code, result, = @machine.run_json('observation', 'check', OBSERVATION)

      assert_equal 3, code, text
      assert_equal 'OBSERVATION_NOT_FOUND', result[:error][:code], text
    end
  end

  def test_a_game_without_a_prefix_is_not_a_missing_installation
    @machine.install_game(@machine.steam_root, compat: false)
    settings = status[1][:data][:settings]

    assert_equal 'unavailable', settings[:state]
    assert_match(/no data directory/, settings[:reason])
  end

  def test_an_unreadable_option_file_is_not_a_capability
    @machine.install_game(@machine.steam_root)

    assert_equal 'unavailable', capability('settings.read_file')[:state]
    @machine.write_options(OptionFiles.sample)

    assert_equal 'observe_only', capability('settings.read_file')[:state]
  end
end

# An X server that stops answering must not read as a window that does not exist.
class LostXServerTest < Minitest::Test
  # A connection opens with four extension queries and the compositing manager's atom, so the sixth
  # request is the first of the search for the game's window.
  REQUESTS_BEFORE_THE_WINDOW_SEARCH = 5
  # RandR's version, its resources, one CRTC and one output end every look.
  REQUESTS_READING_THE_SCREEN = 4

  def setup
    @machine = Machine.new
    @machine.full_game(width: 100, height: 100)
    @server = @machine.x_server
    @server.client_timeout = 0.05
  end

  def teardown = @machine.destroy

  def assert_timed_out(*argv)
    code, result, = @machine.run_json(*argv)

    assert_equal 1, code, argv.join(' ')
    assert_equal 'TIMEOUT', result[:error][:code], argv.join(' ')
    assert_equal 'timed_out', result[:data][:x11][:status]
    result
  end

  def test_silence_from_the_start_is_a_timeout
    @server.silent = true

    assert_equal 'unknown', assert_timed_out('status')[:data][:window][:state]
  end

  def test_a_timeout_during_the_window_search_is_not_a_missing_window
    @server.silent_after = REQUESTS_BEFORE_THE_WINDOW_SEARCH
    window = assert_timed_out('status')[:data][:window]

    assert_equal 'unknown', window[:state]
    assert_match(/did not answer/, window[:reason])
  end

  def test_a_timeout_after_the_window_was_found_still_fails_the_report
    @machine.run_json('status')
    @server.requests.clear
    @machine.run_json('status')
    @server.silent_after = @server.requests.size - REQUESTS_READING_THE_SCREEN

    assert_equal 'found', assert_timed_out('status')[:data][:window][:state]
  end

  def test_commands_that_need_the_window_answer_with_the_timeout
    @server.silent = true

    assert_timed_out('observe')
    assert_timed_out('screenshot')
  end

  def test_capabilities_still_answer_and_say_what_is_missing
    @server.silent = true
    code, result, = @machine.run_json('capabilities')
    window = result[:data][:capabilities].find { it[:id] == 'observe.window' }

    assert_equal 0, code
    assert_equal 'unavailable', window[:state]
    assert_match(/did not answer/, window[:reason])
  end

  def test_doctor_fails_the_check
    @server.silent = true
    code, result, = @machine.run_json('doctor')
    check = result[:data][:checks].find { it[:id] == 'x11' }

    assert_equal 3, code
    assert_equal 'fail', check[:status]
  end

  def test_a_server_that_hangs_up_is_unreachable_and_not_a_missing_window
    @server.hang_up_after = REQUESTS_BEFORE_THE_WINDOW_SEARCH
    code, result, = @machine.run_json('status')

    assert_equal 0, code
    assert_equal 'unavailable', result[:data][:x11][:status]
    assert_equal 'unknown', result[:data][:window][:state]
  end
end

# Steam from Flatpak gives the game a DISPLAY that exists only inside its sandbox.
class SandboxedDisplayTest < Minitest::Test
  def setup
    @machine = Machine.new
    @machine.start_x(width: 100, height: 100)
    @machine.install_game(@machine.steam_root)
    @machine.run_game(env: { 'DISPLAY' => ':99.0' })
    @machine.game_window(width: 100, height: 100)
  end

  def teardown = @machine.destroy

  def data = @machine.run_json('status')[1][:data]

  def test_the_desktops_display_is_tried_and_named
    found = data

    assert_equal 'connected', found[:x11][:status]
    assert_equal @machine.x_server.display, found[:x11][:display]
    assert_equal ':99.0', found[:x11][:game_display]
    assert_equal 'found', found[:window][:state]
  end

  def test_when_no_display_answers_each_one_is_named
    @machine.env['DISPLAY'] = ':98'
    x11 = data[:x11]

    assert_equal 'unavailable', x11[:status]
    assert_match(/server 99/, x11[:reason])
    assert_match(/server 98/, x11[:reason])
  end
end

# A glob character in a directory name must not make a pattern match, or delete from, another one.
class GlobCharactersInPathsTest < Minitest::Test
  def setup
    @machine = Machine.new
    @home = @machine.home
  end

  def teardown = @machine.destroy

  def test_they_cannot_prune_another_directory
    victim = File.join(@home, 'state1/evidence/20260101T000000Z-victim.png')
    FileUtils.mkdir_p(File.dirname(victim))
    File.write(victim, 'not cdctl output of this state directory')
    File.write(File.join(@home, 'config.yaml'), "evidence_keep: 1\n")
    @machine.env.merge!('CDCTL_STATE_HOME' => File.join(@home, 'state[1]'),
                        'CDCTL_CONFIG' => File.join(@home, 'config.yaml'))
    @machine.full_game(width: 100, height: 100)
    @machine.run_json('screenshot', '--request-id', 'first')
    @machine.run_json('screenshot', '--request-id', 'second')

    assert_path_exists victim
    assert_equal 1, Dir.children(File.join(@home, 'state[1]/evidence')).size
  end

  def write_log(prefix, version)
    path = File.join(prefix, Cdctl::Game::Version::LOG_DIRECTORY, 'Launcher_1.log')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "GameVersion: #{version}\n")
  end

  def test_they_do_not_change_which_launch_log_is_read
    write_log(File.join(@home, 'pfx1'), '9.99.99')
    write_log(File.join(@home, 'pfx[1]'), '1.02.03')

    assert_equal '1.02.03', Cdctl::Game::Version.from_log(File.join(@home, 'pfx[1]'))
  end

  def test_they_do_not_change_which_authority_file_is_read
    decoy = File.join(@home, 'run1', 'xauth_decoy')
    mine = File.join(@home, 'run[1]', 'xauth_mine')
    [decoy, mine].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')
    end
    found = Cdctl::X11::Authority.candidate_paths(env: {}, home: @home, runtime_dir: File.join(@home, 'run[1]'))

    assert_includes found, mine
    refute_includes found, decoy
  end
end
