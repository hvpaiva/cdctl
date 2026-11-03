# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class LeaseTest < Minitest::Test
  BOOT = 'boot-one'
  NOW = Time.iso8601('2026-11-03T10:00:00Z')
  REQUEST = 'req-1'

  def setup
    @directory = Dir.mktmpdir('cdctl-lease-')
    @now = NOW
    @processes = { 100 => 5000 }
    @boot = BOOT
  end

  def teardown = FileUtils.remove_entry(@directory)

  def lease
    machine = Cdctl::Lease::Machine.new(host: 'here', boot_id: @boot, start_ticks_of: ->(pid) { @processes[pid] })
    Cdctl::Lease.new(directory: @directory, machine:, clock: -> { @now })
  end

  def acquire(owner = 'agent-a', **) = lease.acquire(owner:, purpose: 'test', request_id: REQUEST, **)

  def assert_code(code, &) = assert_equal(code, assert_raises(Cdctl::Error, &).code)

  def history
    File.readlines(File.join(@directory, 'lease-history.jsonl')).map { JSON.parse(it, symbolize_names: true) }
  end

  def test_a_free_lease_is_a_normal_answer
    assert_equal({ state: 'free', generation: 0 }, lease.status)
  end

  def test_acquire_answers_a_token_and_nothing_else_holds_it
    report, token = acquire

    assert_match Cdctl::Lease::TOKEN, token
    assert_equal %w[held agent-a test], [report[:state], report[:owner], report[:purpose]]
    refute_includes lease.status.to_s, token
    refute_includes lease.status.to_s, 'sha256'
    refute_includes File.read(File.join(@directory, 'lease.json')), token
    refute_includes File.read(File.join(@directory, 'lease-history.jsonl')), token
  end

  def test_the_files_are_readable_by_their_owner_alone
    acquire

    %w[lease.json lease.lock lease-history.jsonl].each do |name|
      assert_equal 0o600, File.stat(File.join(@directory, name)).mode & 0o777, name
    end
    assert_equal 0o700, File.stat(@directory).mode & 0o777
  end

  def test_a_second_owner_is_refused_and_told_who_holds_it
    acquire
    error = assert_raises(Cdctl::Error) { acquire('agent-b') }

    assert_equal 'LEASE_BUSY', error.code
    assert_includes error.message, 'agent-a'
    assert_equal 'agent-a', error.data[:owner]
    refute_includes error.data.to_s, 'sha256'
  end

  def test_each_acquire_raises_the_generation
    _, first = acquire
    lease.release(first, request_id: REQUEST)
    report, second = acquire('agent-b')

    assert_equal 2, report[:generation]
    assert second.start_with?('cdl-2-')
  end

  def test_a_token_works_until_it_is_released
    _, token = acquire

    assert_equal 'agent-a', lease.verify!(token)[:owner]
    lease.release(token, request_id: REQUEST)

    assert_code('LEASE_LOST') { lease.verify!(token) }
  end

  def test_releasing_twice_is_one_request_delivered_twice
    _, token = acquire
    _, first = lease.release(token, request_id: REQUEST)
    report, second = lease.release(token, request_id: 'req-2')

    assert first
    refute second
    assert_equal 'free', report[:state]
  end

  def test_a_late_release_cannot_end_a_newer_lease
    _, old = acquire
    lease.release(old, request_id: REQUEST)
    _, current = acquire('agent-b')

    assert_code('LEASE_LOST') { lease.release(old, request_id: 'late') }
    assert_equal 'agent-b', lease.verify!(current)[:owner]
  end

  def test_a_late_renew_cannot_revive_a_released_lease
    _, token = acquire
    lease.release(token, request_id: REQUEST)

    assert_code('LEASE_LOST') { lease.renew(token, request_id: 'late') }
    assert_equal 'free', lease.status[:state]
  end

  def test_a_made_up_token_never_matches
    acquire

    [nil, '', 'cdl-1-short', "cdl-1-#{'0' * 32}"].compact.each do |token|
      assert_code('LEASE_LOST') { lease.verify!(token) }
    end
  end

  def test_no_token_is_a_different_answer_while_free_and_while_held
    assert_code('LEASE_REQUIRED') { lease.verify!(nil) }
    acquire

    assert_code('LEASE_BUSY') { lease.verify!(nil) }
  end

  def test_renew_records_a_heartbeat
    _, token = acquire
    @now = NOW + 30

    assert_in_delta 30, lease.status[:heartbeat_age_seconds], 0.01
    assert_in_delta 0, lease.renew(token, request_id: 'req-2')[:heartbeat_age_seconds], 0.01
  end

  def test_silence_only_raises_a_suspicion
    _, token = acquire
    @now = NOW + Cdctl::Lease::QUIET_AFTER_SECONDS + 1
    status = lease.status

    assert_equal 'held', status[:state]
    assert status[:orphan][:suspected]
    assert_equal ['owner_silent'], status[:orphan][:reasons]
    assert_code('LEASE_BUSY') { acquire('agent-b') }
    assert lease.verify!(token)
  end

  def test_a_restart_of_the_machine_is_a_suspicion
    acquire
    @boot = 'boot-two'

    assert_equal ['machine_restarted'], lease.status[:orphan][:reasons]
  end

  def test_the_end_of_the_named_process_is_a_suspicion
    acquire(holder_pid: 100)

    refute lease.status[:orphan][:suspected]
    @processes[100] = 9999

    assert_equal ['holder_process_gone'], lease.status[:orphan][:reasons]
    @processes.delete(100)

    assert_equal ['holder_process_gone'], lease.status[:orphan][:reasons]
  end

  def test_naming_a_process_that_does_not_exist_is_refused
    assert_raises(Cdctl::CLI::UsageError) { acquire(holder_pid: 4321) }
  end

  def test_a_takeover_needs_a_reason
    acquire
    @boot = 'boot-two'

    assert_raises(Cdctl::CLI::UsageError) { acquire('agent-b', takeover: true) }
  end

  def test_a_live_owner_is_not_taken_over_without_force
    acquire

    assert_code('LEASE_BUSY') { acquire('agent-b', takeover: true, reason: 'mine now') }
    assert_equal 'agent-a', lease.status[:owner]
  end

  def test_a_takeover_of_an_orphan_fences_the_old_token_and_is_logged
    _, old = acquire
    @boot = 'boot-two'
    report, new = acquire('agent-b', takeover: true, reason: 'the machine restarted')

    assert_equal 'agent-a', report[:taken_from]
    assert_equal 2, report[:generation]
    assert_code('LEASE_LOST') { lease.verify!(old) }
    assert_code('LEASE_LOST') { lease.release(old, request_id: 'late') }
    assert lease.verify!(new)
    takeover = history.find { it[:event] == 'takeover' }

    assert_equal ['agent-a', 'agent-b', 'the machine restarted'], takeover.values_at(:owner, :by, :reason)
  end

  def test_force_takes_over_a_live_owner
    acquire
    report, = acquire('agent-b', takeover: true, force: true, reason: 'the owner asked me to')

    assert_equal 'agent-b', report[:owner]
  end

  def test_a_damaged_file_is_never_read_as_free
    FileUtils.mkdir_p(@directory)
    File.write(File.join(@directory, 'lease.json'), 'not json')

    assert_equal 'unknown', lease.status[:state]
    assert_code('LEASE_BUSY') { acquire }
    assert_code('PRECONDITION_FAILED') { lease.verify!('cdl-1-abc') }
    assert_equal 'agent-b', acquire('agent-b', takeover: true, force: true, reason: 'damaged').first[:owner]
  end

  def test_a_file_of_the_wrong_shape_counts_as_damaged
    ['[]', '{"generation":"7","state":"free"}', '{"generation":1,"state":"held","renewed_at":"soon"}',
     '{"generation":1}'].each do |text|
      File.write(File.join(@directory, 'lease.json'), text)

      assert_equal 'unknown', lease.status[:state], text
    end
  end

  # Several real processes, because a lock that only works inside one process proves nothing.
  def test_only_one_of_many_processes_wins
    results = Array.new(12) do |index|
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        begin
          _, token = lease.acquire(owner: "agent-#{index}", purpose: 'race', request_id: "r#{index}")
          writer.write(token)
        rescue Cdctl::Error => e
          writer.write(e.code)
        end
        writer.close
        exit!(0)
      end
      writer.close
      [pid, reader]
    end
    answers = results.map do |pid, reader|
      Process.wait(pid)
      reader.read.tap { reader.close }
    end

    assert_equal 1, answers.count { it.start_with?('cdl-') }, answers.inspect
    assert_equal 11, answers.count('LEASE_BUSY'), answers.inspect
    assert_equal 1, lease.status[:generation]
  end

  # flock ends with its process, so a crash inside the critical section leaves no lock behind.
  def test_a_process_killed_while_holding_the_lock_leaves_no_lock
    FileUtils.mkdir_p(@directory)
    ready_reader, ready_writer = IO.pipe
    pid = fork do
      File.open(File.join(@directory, 'lease.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        ready_writer.write('x')
        ready_writer.close
        sleep
      end
    end
    ready_writer.close
    ready_reader.read(1)
    Process.kill('KILL', pid)
    Process.wait(pid)

    assert_equal 'held', acquire.first[:state]
  end

  def test_a_lock_that_stays_taken_is_a_timeout_not_a_hang
    FileUtils.mkdir_p(@directory)
    File.open(File.join(@directory, 'lease.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_code('TIMEOUT') { acquire }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<,
                      Cdctl::Lease::Store::LOCK_TIMEOUT + 1
    end
  end

  def test_owner_and_purpose_are_validated
    ['', "line\nfeed", 'x' * 201].each do |text|
      assert_raises(Cdctl::CLI::UsageError) { lease.acquire(owner: text, purpose: 'p', request_id: REQUEST) }
      assert_raises(Cdctl::CLI::UsageError) { lease.acquire(owner: 'o', purpose: text, request_id: REQUEST) }
    end
  end

  def test_the_history_stays_bounded
    _, token = acquire
    (Cdctl::Lease::Store::HISTORY_KEEP * 3).times do |index|
      lease.release(token, request_id: "r#{index}")
      _, token = acquire
    end

    assert_operator history.size, :<=, (Cdctl::Lease::Store::HISTORY_KEEP * 2) + 1
    assert_equal 'acquire', history.last[:event]
  end
end

class LeaseCommandTest < Minitest::Test
  include SchemaAssertions

  def setup = @machine = Machine.new
  def teardown = @machine.destroy

  def acquire(*extra) = @machine.run_json('lease', 'acquire', '--owner', 'agent-a', '--purpose', 'a test', *extra)

  def test_acquire_answers_as_json
    status, result, = acquire

    assert_equal 0, status
    assert_valid 'lease.acquire', result
    assert result[:changed]
    assert_equal 'lease_acquired', result[:actions].first[:type]
  end

  def test_renew_and_release_answer_as_json
    token = acquire[1][:data][:token]
    status, renewed, = @machine.run_json('lease', 'renew', '--token', token)

    assert_equal 0, status
    assert_valid 'lease.renew', renewed
    refute_includes renewed.to_s, token

    status, released, = @machine.run_json('lease', 'release', '--token', token)

    assert_equal 0, status
    assert_valid 'lease.release', released
    assert_equal 'free', released[:data][:state]
  end

  def test_status_is_valid_free_and_held
    _, free, = @machine.run_json('lease', 'status')

    assert_valid 'lease.status', free
    assert_equal 'free', free[:data][:state]

    acquire
    _, held, = @machine.run_json('lease', 'status')

    assert_valid 'lease.status', held
    assert_equal 'agent-a', held[:data][:owner]
    refute held[:changed]
  end

  def test_the_token_can_come_from_the_environment
    _, result, = acquire
    @machine.env['CDCTL_LEASE_TOKEN'] = result[:data][:token]
    status, released, = @machine.run_json('lease', 'release')

    assert_equal 0, status
    assert released[:changed]
  end

  def test_a_second_release_changed_nothing
    _, result, = acquire
    token = result[:data][:token]
    @machine.run_json('lease', 'release', '--token', token)
    status, again, = @machine.run_json('lease', 'release', '--token', token)

    assert_equal 0, status
    refute again[:changed]
    assert_empty again[:actions]
  end

  def test_busy_and_lost_answer_with_exit_status_three
    _, first, = acquire
    status, busy, = acquire

    assert_equal 3, status
    assert_equal 'LEASE_BUSY', busy[:error][:code]
    refute_empty busy[:next_steps]

    status, lost, = @machine.run_json('lease', 'renew', '--token', "cdl-9-#{'0' * 32}")

    assert_equal 3, status
    assert_equal 'LEASE_LOST', lost[:error][:code]
    refute_includes lost.to_s, first[:data][:token]
  end

  def test_a_missing_token_is_a_usage_error
    status, result, = @machine.run_json('lease', 'release')

    assert_equal 2, status
    assert_equal 'USAGE', result[:error][:code]
  end

  def test_required_flags_are_required
    status, result, = @machine.run_json('lease', 'acquire', '--owner', 'only-me')

    assert_equal 2, status
    assert_includes result[:error][:message], '--purpose'
  end

  def test_holder_pid_must_be_a_number_of_a_real_process
    assert_equal 2, acquire('--holder-pid', 'abc').first
    assert_equal 2, acquire('--holder-pid', '99999').first
    @machine.add_process(321, comm: 'agent', argv: ['agent'], start_ticks: 77)
    status, result, = acquire('--holder-pid', '321')

    assert_equal 0, status
    assert_equal({ pid: 321, start_ticks: 77 }, result[:data][:holder])
  end

  def test_takeover_flags_reach_the_lease
    acquire
    status, result, = acquire('--takeover', '--force', '--reason', 'testing it')

    assert_equal 0, status
    assert_equal 'agent-a', result[:data][:taken_from]
  end

  def test_status_reports_the_lease_without_the_token
    @machine.full_game
    _, acquired, = acquire
    _, result, = @machine.run_json('status')

    assert_valid 'status', result
    assert_equal 'held', result[:data][:lease][:state]
    refute_includes result.to_s, acquired[:data][:token]
  end

  def test_human_output
    status, out, = @machine.run('lease', 'acquire', '--owner', 'agent-a', '--purpose', 'a test')

    assert_equal 0, status
    assert_match(/Token\s+cdl-1-/, out)
    assert_match(/Owner\s+agent-a/, out)

    status, out, = @machine.run('lease', 'status')

    assert_equal 0, status
    refute_match(/cdl-1-/, out)
    assert_match(/Orphan\s+no/, out)
  end

  def test_capabilities_list_it_as_available
    _, result, = @machine.run_json('capabilities')
    entry = result[:data][:capabilities].find { it[:id] == 'lease' }

    assert_equal 'available', entry[:state]
  end
end
