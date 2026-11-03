# frozen_string_literal: true

require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'json'
require 'cdctl/game'

# Stands in for hyprctl and grim. An unknown program is not installed, which is the default on a
# machine that is not the author's.
class FakeShell
  attr_reader :calls

  def initialize
    @programs = {}
    @calls = []
  end

  def on(*prefix, stdout: '', stderr: '', status: 0, raises: nil, &block)
    @programs[prefix] = { stdout:, stderr:, status:, raises:, block: }
  end

  def run(*argv, timeout: nil)
    _ = timeout
    @calls << argv
    match = @programs.keys.select { argv.first(it.size) == it }.max_by(&:size)
    raise Cdctl::Shell::NotAvailable, "#{argv.first}: No such file or directory" unless match

    entry = @programs[match]
    raise entry[:raises] if entry[:raises]

    stdout = entry[:block] ? entry[:block].call(argv) : entry[:stdout]
    Cdctl::Shell::Output.new(stdout:, stderr: entry[:stderr], exit_status: entry[:status])
  end
end

# A complete imaginary computer: a home directory, a /proc, optional Steam trees, an optional X
# server and no compositor. Each test adds only what its machine has.
class Machine
  APP_ID = Cdctl::Game::APP_ID
  GAME_WINDOW = 0x5000001
  WINE_PATH = 'S:\\steamapps\\common\\Crimson Desert\\bin64\\CrimsonDesert.exe'
  BOOT_TIME = 1_000_000
  # Before the imaginary boot, so an option file is older than the process unless a test says not.
  LONG_AGO = Time.at(BOOT_TIME - 1000)
  ANOTHER_WINDOW_TITLE = 'Private document of another program'

  attr_reader :home, :proc_root, :shell, :x_server
  attr_accessor :platform, :env, :x11_opener

  def initialize
    @base = Dir.mktmpdir('cdctl-machine-')
    @home = File.join(@base, 'home')
    @proc_root = File.join(@base, 'proc')
    FileUtils.mkdir_p([@home, File.join(@proc_root, 'sys/kernel/random')])
    File.write(File.join(@proc_root, 'sys/kernel/random/boot_id'), "abcdef01-0000-0000-0000-000000000000\n")
    File.write(File.join(@proc_root, 'stat'), "cpu 0\nbtime #{BOOT_TIME}\n")
    @shell = FakeShell.new
    @platform = Cdctl::Platform::LINUX
    @env = { 'HOME' => @home }
  end

  def destroy
    @x_server&.stop
    FileUtils.remove_entry(@base)
  end

  def runtime
    paths = Cdctl::Paths.new(env, platform:)
    Cdctl::Runtime.new(env:, paths:, settings: Cdctl::Settings.load(paths), platform:, proc_root:, shell:,
                       x11_opener: x11_opener || (x_server ? x_server.opener : method(:no_x_server)))
  end

  def no_x_server(display, cookies: [])
    _ = cookies
    raise Cdctl::X11::ConnectError, "cannot reach X server #{display}"
  end

  def start_x(width: 1920, height: 1080)
    @x_server = FakeXServer.new(width:, height:)
    env['DISPLAY'] = @x_server.display
    @x_server
  end

  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    context = Cdctl::CLI::Context.new(out:, err:, env:)
    status = Cdctl.run(argv, context:, runtime_factory: ->(_context, _opts) { runtime })
    [status, out.string, err.string]
  end

  def run_json(*argv)
    status, out, err = run(*argv, '--json')
    [status, JSON.parse(out, symbolize_names: true), err]
  end

  # Steam ----------------------------------------------------------------------------------------

  def steam_root(relative = '.local/share/Steam', libraries: [])
    root = File.join(home, relative)
    FileUtils.mkdir_p(File.join(root, 'steamapps'))
    write_library_folders(root, [root, *libraries])
    root
  end

  def write_library_folders(root, paths)
    entries = paths.each_with_index.map do |path, index|
      %(\t"#{index}"\n\t{\n\t\t"path"\t\t"#{path}"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n)
    end
    File.write(File.join(root, 'steamapps/libraryfolders.vdf'), %("libraryfolders"\n{\n#{entries.join}}\n))
  end

  def install_game(library, build: '111', depot: '999', flags: 4, language: 'english', installdir: 'Crimson Desert',
                   compat: true, version: [2, 4, 5], options: nil)
    steamapps = File.join(library, 'steamapps')
    FileUtils.mkdir_p(File.join(steamapps, 'common', installdir, 'meta'))
    File.write(File.join(steamapps, "appmanifest_#{APP_ID}.acf"),
               manifest(build:, depot:, flags:, language:, installdir:))
    File.binwrite(File.join(steamapps, 'common', installdir, 'meta/0.paver'), version.pack('v3')) if version
    make_compat(steamapps, options) if compat
    library
  end

  def manifest(build:, depot:, flags:, language:, installdir:)
    <<~ACF
      "AppState"
      {
      \t"appid"\t\t"#{APP_ID}"
      \t"name"\t\t"Crimson Desert"
      \t"StateFlags"\t\t"#{flags}"
      \t"installdir"\t\t"#{installdir}"
      \t"buildid"\t\t"#{build}"
      \t"InstalledDepots"
      \t{
      \t\t"1"
      \t\t{
      \t\t\t"manifest"\t\t"#{depot}"
      \t\t}
      \t}
      \t"UserConfig"
      \t{
      \t\t"language"\t\t"#{language}"
      \t}
      }
    ACF
  end

  def make_compat(steamapps, options)
    compat = File.join(steamapps, 'compatdata', APP_ID.to_s)
    save = File.join(compat, 'pfx/drive_c/users/steamuser/AppData/Local/Pearl Abyss/CD/save')
    FileUtils.mkdir_p(save)
    File.write(File.join(compat, 'version'), "9.0-1\n")
    write_options(options, modified_at: LONG_AGO, steamapps:) if options
    compat
  end

  # Written now unless told otherwise, which makes the file newer than any running game.
  def write_options(options, modified_at: Time.now, steamapps: File.join(home, '.local/share/Steam/steamapps'))
    path = File.join(steamapps, 'compatdata', APP_ID.to_s,
                     'pfx/drive_c/users/steamuser/AppData/Local/Pearl Abyss/CD/save/user_engine_option_save.xml')
    File.write(path, options)
    File.utime(modified_at, modified_at, path)
  end

  # Processes ------------------------------------------------------------------------------------

  def add_process(pid, comm:, argv:, env: {}, state: 'S', parent: 1, start_ticks: 5000)
    directory = File.join(proc_root, pid.to_s)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'comm'), "#{comm}\n")
    File.binwrite(File.join(directory, 'cmdline'), "#{argv.join("\0")}\0")
    File.binwrite(File.join(directory, 'environ'), env.map { |key, value| "#{key}=#{value}" }.join("\0"))
    fields = [state, parent, *Array.new(17, 0), start_ticks, 0, 0].join(' ')
    File.write(File.join(directory, 'stat'), "#{pid} (#{comm}) #{fields}\n")
  end

  # A game whose process can be told apart, on a machine with a compositor that proves it is on top.
  def playable_game(**)
    full_game(**)
    hyprland
    GAME_WINDOW
  end

  def lease_token
    run_json('lease', 'acquire', '--owner', 'test', '--purpose', 'a test')[1][:data][:token]
  end

  def run_game(pid: 4242, env: {}, parent: 1, start_ticks: 5000)
    defaults = { 'SteamAppId' => APP_ID.to_s, 'DISPLAY' => self.env['DISPLAY'], 'SECRET_TOKEN' => 'hunter2' }.compact
    add_process(pid, comm: 'CrimsonDesert.e', parent:, start_ticks:, env: defaults.merge(env),
                     argv: [WINE_PATH, 'PlatformServiceType=Steam'])
    pid
  end

  def game_window(pid: 4242, width: 1920, height: 1080, x: 0, y: 0, focused: true, pixel: 0x102030)
    start_x(width:, height:) unless x_server
    x_server.add_window(GAME_WINDOW, x:, y:, width:, height:, pixel:,
                                     WM_CLASS: "steam_app_#{APP_ID}\0steam_app_#{APP_ID}\0",
                                     STEAM_GAME: [APP_ID], _NET_WM_PID: [pid], WM_NAME: 'Crimson Desert')
    x_server.client_list(GAME_WINDOW)
    x_server.focus = GAME_WINDOW if focused
    GAME_WINDOW
  end

  # A running game on a machine with Steam and X, and no compositor.
  def full_game(width: 1920, height: 1080, options: nil)
    start_x(width:, height:) unless x_server
    install_game(steam_root, options:)
    run_game
    game_window(width:, height:)
  end

  # Hyprland -------------------------------------------------------------------------------------

  def hyprland(active_pid: 4242, width: 1920, height: 1080, layers: {}, x: 0, y: 0, locked: false, fullscreen: 2,
               monitors: nil, client_pid: 4242)
    shell.on('hyprctl', 'instances', '-j', stdout: JSON.generate([{ 'instance' => 'sig' }]))
    client = { 'class' => "steam_app_#{APP_ID}", 'title' => 'Crimson Desert', 'pid' => client_pid, 'at' => [x, y],
               'size' => [width, height], 'monitor' => 0, 'workspace' => { 'name' => '1' }, 'fullscreen' => fullscreen }
    active = if active_pid == client_pid
               client
             else
               client.merge('class' => 'other.program', 'title' => ANOTHER_WINDOW_TITLE, 'pid' => active_pid)
             end
    {
      'version' => { 'tag' => 'v1.2.3' }, 'clients' => [client], 'activewindow' => active,
      'monitors' => monitors || [monitor(0, 'OUT-1', width, height)], 'locked' => { 'locked' => locked },
      'layers' => { 'OUT-1' => { 'levels' => layers } }
    }.each { |topic, body| shell.on('hyprctl', '-i', 'sig', '-j', topic, stdout: JSON.generate(body)) }
  end

  def monitor(id, name, width, height, focused: true)
    { 'id' => id, 'name' => name, 'width' => width, 'height' => height, 'refreshRate' => 60.0, 'scale' => 1, 'x' => 0,
      'y' => 0, 'focused' => focused }
  end
end
