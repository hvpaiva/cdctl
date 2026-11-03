# frozen_string_literal: true

require 'time'
require_relative 'capture/screen_guard'
require_relative 'compositor'
require_relative 'fact'
require_relative 'game'
require_relative 'game/options_file'
require_relative 'game/process_scanner'
require_relative 'game/version'
require_relative 'game_window'
require_relative 'ledger'
require_relative 'modals'
require_relative 'resolution'
require_relative 'snapshot'
require_relative 'steam/locator'
require_relative 'x11/authority'
require_relative 'x11/connection'

module Cdctl
  # Takes one look at the machine. It only reads: Steam's files, /proc, the game's X server, the
  # compositor's status and the option file. A source that fails becomes a reason in the report,
  # so one missing piece never hides the rest. The ledger under the state directory is the only
  # thing it writes, and that belongs to cdctl.
  class Observer
    EXTENSIONS = %w[XTEST XInputExtension RANDR].freeze
    XWAYLAND = 'XWAYLAND'

    attr_reader :connection

    def self.open(runtime)
      observer = new(runtime)
      yield observer
    ensure
      observer&.close
    end

    def initialize(runtime)
      @runtime = runtime
    end

    def close = @connection&.close

    def snapshot
      observed_at = Time.now.iso8601(3)
      steam = locate_steam
      scan = scan_processes
      process = scan&.processes&.one? ? scan.processes.first : nil
      installation = choose_installation(steam, process)
      connect(process)
      windows = find_windows(process)
      compositor = observe_compositor(process)
      options_path, options = read_options(installation)
      resolution = assess(process, windows&.one? ? windows.first : nil, compositor, options)
      Snapshot.new(
        observed_at:, platform: @runtime.platform, steam:, installation:, scan:, x11: @x11, windows:, compositor:,
        modals: assess_modals(compositor, process), options_path:, options:, resolution:,
        version: Game::Version.read(installation)
      )
    end

    def screen_guard(process)
      Capture::ScreenGuard.new(observe: compositor_probe(process), pid: process.pid,
                               ignored: @runtime.settings.ignored_overlay_layers)
    end

    def compositor_probe(process) = -> { observe_compositor(process) }

    # Another connection to the same server, for a part that must keep working if this one fails.
    def connection_opener(process)
      display = @x11.fetch(:display)
      credentials = cookies(display, process)
      -> { @runtime.x11_opener.call(display, cookies: credentials) }
    end

    private

    def assess_modals(compositor, process)
      Modals.assess(compositor, ignored: @runtime.settings.ignored_overlay_layers, pid: process&.pid)
    end

    def observe_compositor(process)
      unless @runtime.linux?
        return Compositor::State.none(@runtime.env['XDG_CURRENT_DESKTOP'], "no driver on #{@runtime.platform}")
      end

      Compositor.observe(shell: @runtime.shell, env: @runtime.env, game_pid: process&.pid)
    end

    def locate_steam
      candidates = Steam::Roots.candidates(platform: @runtime.platform, home: @runtime.paths.home, env: @runtime.env,
                                           configured: @runtime.settings.steam_root)
      Steam::Locator.new(candidates:, app_id: Game::APP_ID).locate
    end

    def scan_processes
      return nil unless @runtime.linux?

      Game::ProcessScanner.new(proc_root: @runtime.proc_root).scan
    end

    # With several installations only the running game can say which one is meant.
    def choose_installation(steam, process)
      found = steam.installations
      return found.first if found.one?

      path = process&.compat_data_path
      path && found.find { it.compat_data_path && File.realpath(it.compat_data_path) == File.realpath(path) }
    rescue SystemCallError
      nil
    end

    # The game's own DISPLAY first: under a nested compositor it is not the desktop's. A sandboxed
    # Steam gives the game a number that exists only inside the sandbox, so the desktop's is tried
    # next. The window's own properties prove afterwards whether it was the right server.
    def connect(process)
      displays = [process&.display, @runtime.env['DISPLAY']].reject { it.to_s.empty? }.uniq
      @x11 = { status: 'unavailable', reason: no_display_reason }
      return unless @runtime.linux? && !displays.empty?

      refusals = []
      displays.each do |display|
        @x11 = { status: 'connected', display: }
        return open_display(display, process)
      rescue X11::ConnectError => e
        close
        @connection = nil
        refusals << e.message
      end
      @x11 = { status: 'unavailable', display: displays.first, reason: refusals.uniq.join('; ') }
    rescue X11::TimeoutError, X11::ClosedError => e
      lost(e)
    end

    def no_display_reason
      @runtime.linux? ? 'no DISPLAY is known' : "X11 is not used on #{@runtime.platform}"
    end

    def open_display(display, process)
      @connection = @runtime.x11_opener.call(display, cookies: cookies(display, process))
      @x11[:extensions] = EXTENSIONS.to_h { [it, !@connection.extension(it).nil?] }
      @x11[:xwayland] = !@connection.extension(XWAYLAND).nil?
      @x11[:compositing_manager] =
        @connection.selection_owned?("_NET_WM_CM_S#{X11::Display.parse(display).screen}")
      @x11[:game_display] = process.display if process&.display && process.display != display
    end

    # A timeout leaves the connection unusable, and it must not read as a window that does not exist.
    def lost(error)
      status = error.is_a?(X11::TimeoutError) ? 'timed_out' : 'unavailable'
      @x11 = { status:, display: @x11[:display], reason: error.message }.compact
      close
      @connection = nil
    end

    def cookies(display, process)
      paths = X11::Authority.candidate_paths(env: @runtime.env, home: @runtime.paths.home,
                                             runtime_dir: @runtime.paths.runtime_dir,
                                             process_path: process&.environment&.fetch('XAUTHORITY', nil))
      X11::Authority.cookies(X11::Display.parse(display).number, paths)
    end

    def find_windows(process)
      return nil unless @connection && process

      WindowFinder.new(@connection, app_id: Game::APP_ID, window_class: Game::WINDOW_CLASS, pid: process.pid).candidates
    rescue X11::TimeoutError, X11::ClosedError => e
      lost(e)
      nil
    rescue X11::RequestError
      []
    end

    def read_options(installation)
      path = Game::OptionsFile.location(installation, platform: @runtime.platform, env: @runtime.env)
      return [nil, no_options_reason(installation)] unless path
      return [path, 'the file does not exist yet'] unless File.file?(path)

      [path, Game::OptionsFile.read(path)]
    rescue Game::OptionsFile::ParseError => e
      [path, e.message]
    end

    def no_options_reason(installation)
      installation ? 'the game has no data directory yet' : 'the game installation was not found'
    end

    def assess(process, window, compositor, options)
      screen = game_screen(window)
      display = display_mode(compositor, screen, process)
      witness = witness_of_display(display, screen, process)
      Resolution.new(window:, screen:, display:, options:, nested: process&.nested? || false,
                     baseline: baseline(process, window, witness), witness:, started_at: process&.started_at).to_h
    end

    def game_screen(window)
      return Fact.unknown('X11 is not reachable') unless @connection

      outputs = @connection.outputs
      return Fact.unknown('the X server has no RandR extension') unless outputs

      output = pick_output(outputs, window)
      return Fact.unknown('no active output can be tied to the game') unless output

      Fact.known(output.to_h, source: 'x11_randr')
    rescue X11::TimeoutError, X11::ClosedError => e
      lost(e)
      Fact.unknown(e.message)
    rescue X11::RequestError => e
      Fact.unknown(e.message)
    end

    # Among several outputs only the window can say which one, and the first would be a guess.
    def pick_output(outputs, window)
      return outputs.first if outputs.one?
      return nil unless window

      x, y = window.center
      outputs.find { it.contains?(x, y) }
    end

    # A nested game sees a screen of its own, so X says nothing about the real monitor there. Nor
    # does Xwayland, whose outputs are its own view of the monitors, close to their modes and not
    # the modes themselves. Only a plain X server reports the mode itself.
    def display_mode(compositor, screen, process)
      return Fact.unknown('the game runs inside a nested compositor') if process&.nested?

      monitor = compositor.relevant_monitor
      return Fact.known(monitor.except(:id, :focused), source: compositor.name) if monitor
      return Fact.unknown('the compositor does not say which monitor the game is on') if compositor.available?
      return Fact.unknown('Xwayland reports its own view of the monitors, not their modes') if @x11[:xwayland]
      return screen if screen.known?

      Fact.unknown('neither the compositor nor X11 reported a display mode')
    end

    # What can show a display change: the mode, or else the screen X reports, which still moves when
    # the monitor does. A nested game's screen stays put whatever happens outside it.
    def witness_of_display(display, screen, process)
      return nil if process&.nested?

      fact = display.known? ? display : screen
      fact.known? ? fact.value.slice(:width, :height).merge(source: fact.source) : nil
    end

    def baseline(process, window, witness)
      return nil unless process && window

      Ledger.new(@runtime.paths.sessions_dir).record(
        process.identity, window: { width: window.width, height: window.height }, display: witness
      )
    end
  end
end
