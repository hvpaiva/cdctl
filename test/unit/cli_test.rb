# frozen_string_literal: true

require 'test_helper'

# What any caller may rely on before a command looks at anything.
class CommandLayerTest < Minitest::Test
  include SchemaAssertions

  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def test_stdout_holds_only_the_document
    _, out, err = @machine.run('schema', '--json')

    assert_equal 1, out.lines.size
    assert JSON.parse(out)
    assert_empty err
  end

  def test_exit_status_follows_the_error_category
    {
      %w[bogus] => 2, %w[schema --nope] => 2, %w[schema bogus] => 2, %w[input key m] => 3, %w[menu open map] => 3,
      %w[hud status] => 4, %w[schema hud.radar] => 4, %w[schema] => 0
    }.each do |argv, expected|
      assert_equal expected, @machine.run(*argv, '--json').first, argv.join(' ')
    end
  end

  def test_every_failure_is_a_document_under_json
    [%w[bogus], %w[schema --nope], %w[input key m], %w[schema --request-id bad/id],
     %w[version --request-id bad/id]].each do |argv|
      _, out, = @machine.run(*argv, '--json')
      result = JSON.parse(out)

      refute result['ok'], argv.join(' ')
      assert_includes Cdctl::ErrorCodes::CODES.keys, result.dig('error', 'code'), argv.join(' ')
    end
  end

  def test_every_way_of_asking_answers_with_a_document_under_json
    asked = { %w[version] => 'version', %w[--version] => 'version', %w[help] => 'help', %w[--help] => 'help',
              %w[-h] => 'help', %w[help schema] => 'help', %w[schema --help] => 'help' }
    asked.each do |argv, name|
      status, out, err = @machine.run(*argv, '--json')
      result = JSON.parse(out)

      assert_equal 0, status, argv.join(' ')
      assert_equal 'ok', result['status'], argv.join(' ')
      assert_empty err, argv.join(' ')
      assert_valid(name, result)
    end
  end

  def test_no_command_at_all_is_a_usage_document_under_json
    status, out, = @machine.run('--json')

    assert_equal 2, status
    assert_equal 'USAGE', JSON.parse(out).dig('error', 'code')
  end

  def test_the_request_id_reaches_every_document
    %w[version --version help --help].each do |word|
      _, out, = @machine.run(word, '--request-id', 'abc-1', '--json')

      assert_equal 'abc-1', JSON.parse(out)['request_id'], word
    end
  end

  def test_a_failure_before_the_command_runs_echoes_the_request_id_too
    [%w[bogus --request-id abc-1 --json], %w[schema --nope --request-id=abc-1 --json],
     %w[--request-id abc-1 --json]].each do |argv|
      _, out, = @machine.run(*argv)

      assert_equal 'abc-1', JSON.parse(out)['request_id'], argv.join(' ')
    end
  end

  def test_a_request_id_that_is_not_valid_is_not_echoed
    _, out, = @machine.run('schema', '--request-id', 'bad/id', '--json')

    refute_equal 'bad/id', JSON.parse(out)['request_id']
  end

  def context_for(out, err: StringIO.new) = Cdctl::CLI::Context.new(out:, err:, env: @machine.env)

  def test_a_signal_answers_with_a_document_and_its_status
    %w[SIGTERM SIGINT SIGHUP].each do |signal|
      out = StringIO.new
      factory = ->(_, _) { raise SignalException, signal }
      status = Cdctl.run(%w[schema --json --request-id abc-1], context: context_for(out), runtime_factory: factory)
      result = JSON.parse(out.string)

      assert_equal 130, status, signal
      assert_equal 'INTERRUPTED', result.dig('error', 'code'), signal
      assert_match(/#{signal}/, result.dig('error', 'message'))
      assert_equal 'schema', result['command'], signal
      assert_equal 'abc-1', result['request_id'], signal
    end
  end

  def test_a_signal_inside_a_command_keeps_its_timing
    out = StringIO.new
    slow = lambda do |_, _|
      sleep(0.02)
      raise SignalException, 'SIGTERM'
    end
    Cdctl.run(%w[schema --json], context: context_for(out), runtime_factory: slow)

    assert_operator JSON.parse(out.string)['duration_ms'], :>=, 20
  end

  def test_a_signal_outside_a_command_answers_too
    out = Object.new
    def out.puts(*) = raise(SignalException, 'SIGTERM')
    err = StringIO.new
    status = Cdctl.run(%w[version], context: context_for(out, err:), runtime_factory: ->(_, _) { @machine.runtime })

    assert_equal 130, status
    assert_match(/stopped by SIGTERM/, err.string)
  end

  def test_a_bad_configuration_file_is_named
    path = File.join(@machine.home, 'config.yaml')
    File.write(path, "nonsense: true\n")
    @machine.env['CDCTL_CONFIG'] = path
    status, _, err = @machine.run('schema')

    assert_equal 3, status
    assert_match(/unknown key "nonsense"/, err)
  end

  def test_help_needs_no_machine_at_all
    ['--help', 'schema --help', 'help schema', 'version'].each do |line|
      status, out, = @machine.run(*line.split)

      assert_equal 0, status, line
      refute_empty out, line
    end
  end

  def test_help_documents_every_exit_status
    _, out, = @machine.run('--help')

    Cdctl::ErrorCodes.exit_statuses.each_key { assert_match(/^\s+#{it}\s/, out) }
  end

  def test_columns_wrap_help
    @machine.env['COLUMNS'] = '40'
    _, out, = @machine.run('--help')

    assert_operator out.lines.map { it.chomp.size }.max, :<=, 60
  end

  def test_planned_commands_are_hidden_from_help_but_answer
    _, out, = @machine.run('--help')

    refute_match(/^\s+hud\s/, out)
    assert_equal 'NOT_IMPLEMENTED', @machine.run_json('hud', 'status')[1][:error][:code]
  end

  def test_unknown_commands_suggest_the_right_one
    _, _, err = @machine.run('schemata')

    assert_match(/Did you mean this\?\n\tschema/, err)
  end

  def test_a_closed_stdout_does_not_change_the_answer
    out = Object.new
    def out.puts(*) = raise(Errno::EPIPE)
    def out.print(*) = raise(Errno::EPIPE)
    factory = ->(_, _) { @machine.runtime }

    assert_equal 0, Cdctl.run(%w[schema --json], context: context_for(out), runtime_factory: factory)
  end
end

class StyleTest < Minitest::Test
  REPLACEMENT = Cdctl::CLI::Style::REPLACEMENT

  def plain(text, **) = Cdctl::CLI::Style.plain(text, **)

  def test_what_a_terminal_would_obey_becomes_visible
    assert_equal '^[[2Jx', plain("\e[2Jx")
    assert_equal 'a^?b', plain("a\x7Fb")
    assert_equal 'a^Ib^Jc', plain("a\tb\nc")
    assert_equal "a#{REPLACEMENT}b", plain("a#{[0x9B].pack('U')}b")
  end

  def test_a_laid_out_message_keeps_its_lines_and_nothing_else
    assert_equal "a\tb\nc", plain("a\tb\nc", layout: true)
    assert_equal '^[', plain("\e", layout: true)
  end

  def test_a_bidirectional_control_cannot_reorder_a_line
    assert_equal "a#{REPLACEMENT}b", plain("a#{[0x202E].pack('U')}b")
  end

  def test_bytes_that_are_not_text_do_not_raise
    assert_equal "a#{REPLACEMENT}b", plain("a\xFFb".b)
  end
end

class RuntimeTest < Minitest::Test
  def test_the_real_runtime_builds_from_the_environment_alone
    Dir.mktmpdir do |home|
      context = Cdctl::CLI::Context.new(out: StringIO.new, err: StringIO.new, env: { 'HOME' => home })
      runtime = Cdctl::Runtime.build(context, {})

      assert_equal File.join(home, '.local/state/cdctl'), runtime.paths.state_home
      refute_includes runtime.inspect, home
    end
  end

  def test_recognizes_each_platform
    {
      'linux-gnu' => 'linux', 'mingw32' => 'windows', 'darwin24' => 'macos', 'freebsd14' => 'other'
    }.each { |host, name| assert_equal name, Cdctl::Platform.current(host) }
  end

  def test_windows_keeps_its_files_in_its_own_places
    paths = Cdctl::Paths.new({ 'USERPROFILE' => 'C:/u', 'LOCALAPPDATA' => 'C:/l', 'APPDATA' => 'C:/a' },
                             platform: Cdctl::Platform::WINDOWS)

    assert_equal 'C:/l/cdctl', paths.state_home
    assert_equal 'C:/a/cdctl/config.yaml', paths.config_file
  end

  def test_a_relative_xdg_directory_is_ignored
    paths = Cdctl::Paths.new({ 'HOME' => '/h', 'XDG_STATE_HOME' => 'relative' }, platform: Cdctl::Platform::LINUX)

    assert_equal '/h/.local/state/cdctl', paths.state_home
  end
end
