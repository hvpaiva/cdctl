# frozen_string_literal: true

require 'test_helper'

class ProcessDiscoveryTest < Minitest::Test
  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def game = @machine.run_json('status')[1][:data][:game]

  def add_wrappers
    path = '/games/steamapps/common/Crimson Desert/bin64/CrimsonDesert.exe'
    @machine.add_process(10, comm: 'python3', argv: ['python3', '/proton', 'waitforexitandrun', path])
    @machine.add_process(11, comm: 'steam.exe', argv: ['c:\\windows\\system32\\steam.exe', path])
    @machine.add_process(12, comm: 'crashpad_handler', argv: ['S:\\bin64\\crashpad_handler.exe', '--database=x'])
  end

  def test_a_truncated_process_name_is_still_the_game
    @machine.run_game(pid: 77)
    found = game

    assert_equal 'running', found[:state]
    assert_equal 77, found[:pid]
    assert_includes found[:evidence], 'comm_prefix'
  end

  def test_processes_that_only_mention_the_game_are_not_the_game
    add_wrappers

    assert_equal 'not_running', game[:state]
  end

  def test_the_real_process_wins_over_its_wrappers
    add_wrappers
    @machine.run_game(pid: 77)

    assert_equal 77, game[:pid]
  end

  def test_steam_starting_the_game_is_its_own_state
    @machine.add_process(9, comm: 'reaper', argv: ['/steam/reaper', 'SteamLaunch', "AppId=#{Machine::APP_ID}", '--'])

    assert_equal 'starting', game[:state]
  end

  def test_a_dead_process_is_not_running
    @machine.add_process(77, comm: 'CrimsonDesert.e', state: 'Z', argv: ['CrimsonDesert.exe'])

    assert_equal 'not_running', game[:state]
  end

  def test_two_instances_are_ambiguous_and_nothing_is_picked
    @machine.run_game(pid: 77)
    @machine.run_game(pid: 78)
    found = game

    assert_equal 'ambiguous', found[:state]
    assert_equal [77, 78], found[:candidates].sort
  end

  def test_another_app_with_the_same_file_name_is_ignored
    @machine.add_process(77, comm: 'CrimsonDesert.e', env: { 'SteamAppId' => '1' }, argv: ['CrimsonDesert.exe'])

    assert_equal 'not_running', game[:state]
  end

  def test_a_nested_compositor_above_the_game_is_noticed
    @machine.add_process(50, comm: 'gamescope-wl', argv: ['gamescope'])
    @machine.add_process(51, comm: 'pv-adverb', argv: ['pv-adverb'], parent: 50)
    @machine.run_game(pid: 77, parent: 51)

    assert game[:nested_compositor]
  end

  def test_the_game_environment_never_reaches_the_output
    @machine.run_game(pid: 77, env: { 'SECRET_TOKEN' => 'hunter2', 'XAUTHORITY' => '/run/x/Xauthority' })
    _, out, = @machine.run('status', '--json')

    refute_includes out, 'hunter2'
    refute_includes out, 'SECRET_TOKEN'
    refute_includes out, 'Xauthority'
  end

  def test_the_identity_changes_when_a_pid_is_reused
    first = Cdctl::Game::ProcessScanner.new(proc_root: @machine.proc_root)
    @machine.run_game(pid: 77, start_ticks: 100)
    before = first.scan.processes.first.identity
    @machine.run_game(pid: 77, start_ticks: 200)

    refute_equal before, first.scan.processes.first.identity
  end
end
