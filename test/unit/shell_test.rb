# frozen_string_literal: true

require 'test_helper'
require 'timeout'

class ShellTest < Minitest::Test
  def shell(env = {}) = Cdctl::Shell.new(env)

  def test_returns_output_and_status
    output = shell.run(RbConfig.ruby, '-e', '$stdout.write("out"); $stderr.write("err"); exit 3')

    assert_equal 'out', output.stdout
    assert_equal 'err', output.stderr
    assert_equal 3, output.exit_status
    refute_predicate output, :success?
  end

  def test_passes_arguments_without_a_shell
    output = shell.run(RbConfig.ruby, '-e', 'print ARGV.first', '; touch /tmp/cdctl-injected $(id)')

    assert_equal '; touch /tmp/cdctl-injected $(id)', output.stdout
    refute_path_exists '/tmp/cdctl-injected'
  end

  def test_a_missing_program_is_not_available
    assert_raises(Cdctl::Shell::NotAvailable) { shell.run('cdctl-no-such-program') }
  end

  def test_a_slow_program_is_killed_at_the_deadline
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Cdctl::Shell::TimedOut) { shell.run(RbConfig.ruby, '-e', 'sleep 30', timeout: 0.2) }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_reads_more_than_a_pipe_buffer_from_both_streams
    code = '$stdout.write("a" * 200_000); $stderr.write("b" * 200_000)'
    output = shell.run(RbConfig.ruby, '-e', code)

    assert_equal [200_000, 200_000], [output.stdout.bytesize, output.stderr.bytesize]
  end

  # The child has its own process group, so the signal that stops cdctl never reaches it directly.
  def test_a_signal_takes_the_child_down_with_it
    script = <<~RUBY
      require 'cdctl/shell'
      begin
        code = 'File.write(ARGV[0] + ".tmp", Process.pid.to_s); File.rename(ARGV[0] + ".tmp", ARGV[0]); sleep 60'
        Cdctl::Shell.new.run(RbConfig.ruby, '-e', code, ARGV[0], timeout: 60)
      rescue SignalException
        exit 42
      end
    RUBY
    Dir.mktmpdir do |directory|
      marker = File.join(directory, 'child')
      parent = Process.spawn(RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-rrbconfig', '-e', script,
                             marker)
      Timeout.timeout(10) { sleep(0.01) until File.exist?(marker) }
      child = File.read(marker).to_i
      Process.kill('TERM', parent)
      _, status = Process.wait2(parent)

      assert_equal 42, status.exitstatus
      assert_raises(Errno::ESRCH) { Process.kill(0, child) }
    end
  end

  def test_adds_the_given_environment
    assert_equal 'yes', shell('CDCTL_TEST' => 'yes').run(RbConfig.ruby, '-e', 'print ENV["CDCTL_TEST"]').stdout
  end
end
