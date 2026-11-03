# frozen_string_literal: true

require_relative 'capture/service'
require_relative 'game'
require_relative 'private_files'

module Cdctl
  # Says what is missing and how to fix it. Only what prevents cdctl from working at all fails; a
  # game that is closed is a normal state, not a problem.
  class Doctor
    MINIMUM_RUBY = Gem::Version.new('3.4')
    WRAPPER_ONLY = 'Steam is starting the game, or it has just closed'

    def initialize(snapshot:, connection:, paths:)
      @snapshot = snapshot
      @connection = connection
      @paths = paths
    end

    def checks
      [platform, ruby, steam, installation, compat_data, option_file, state_directory, process, x11, input_extension,
       window, capture, compositor, dialogs]
    end

    private

    def check(id, status, detail, remedy = nil) = { id:, status:, detail:, remedy: }.compact

    def platform
      return check('platform', 'ok', 'Linux') if @snapshot.linux?

      check('platform', 'warn', "#{@snapshot.platform} has discovery only for now",
            'Observation commands answer UNSUPPORTED_PLATFORM until a driver for this system exists.')
    end

    def ruby
      current = Gem::Version.new(RUBY_VERSION)
      return check('ruby', 'ok', RUBY_VERSION) if current >= MINIMUM_RUBY

      check('ruby', 'fail', "#{RUBY_VERSION} is older than #{MINIMUM_RUBY}",
            'Install a newer Ruby, for example with mise.')
    end

    def steam
      roots = @snapshot.steam.roots
      return check('steam', 'ok', roots.join(', ')) unless roots.empty?

      check('steam', 'fail', "no Steam directory among #{@snapshot.steam.searched.size} searched",
            'Set CDCTL_STEAM_ROOT or steam_root in the configuration file if Steam is elsewhere.')
    end

    def installation
      found = @snapshot.installation
      return installation_problem unless found
      return check('installation', 'ok', "#{found.name} build #{found.build_id}") if found.fully_installed?

      check('installation', 'warn', "state flags #{found.state_flags}: an update or download may be pending",
            'Let Steam finish, then run this again.')
    end

    def installation_problem
      many = @snapshot.steam.installations.size > 1
      if many
        return check('installation', 'warn', 'several libraries hold the game',
                     'Start the game, or pin one with CDCTL_STEAM_ROOT.')
      end

      detail = @snapshot.steam.problems.first || "no library holds app #{Game::APP_ID}"
      check('installation', 'fail', detail, 'Install the game through Steam.')
    end

    def compat_data
      return check('compat_data', 'skip', 'not used on this platform') unless @snapshot.linux?

      found = @snapshot.installation&.compat_data_path
      return check('compat_data', 'ok', "Proton #{@snapshot.installation.proton_version || 'version unknown'}") if found

      check('compat_data', 'info', 'no Proton prefix yet', 'It appears after the first launch through Steam.')
    end

    def option_file
      return check('option_file', 'ok', @snapshot.options.path) if @snapshot.options.respond_to?(:path)

      check('option_file', 'info', @snapshot.options.to_s, 'The game writes it when settings are applied.')
    end

    def state_directory
      directory = @paths.state_home
      PrivateFiles.directory(directory)
      probe = File.join(directory, '.doctor-probe')
      PrivateFiles.write(probe, 'ok')
      File.unlink(probe)
      check('state_directory', 'ok', directory)
    rescue SystemCallError => e
      check('state_directory', 'fail', "#{directory}: #{e.message}", 'Set CDCTL_STATE_HOME to a writable directory.')
    end

    def process
      return check('game_process', 'skip', 'not available on this platform') unless @snapshot.scan

      return check('game_process', 'fail', @snapshot.scan.problem) if @snapshot.scan.problem

      found = @snapshot.process
      return check('game_process', 'info', "running as PID #{found.pid}") if found
      return check('game_process', 'warn', 'several processes match the game') if @snapshot.scan.processes.size > 1

      check('game_process', 'info', @snapshot.scan.launching ? WRAPPER_ONLY : 'the game is not running')
    end

    def x11
      return check('x11', 'skip', 'not used on this platform') unless @snapshot.linux?

      reason = @snapshot.x11[:reason]
      case @snapshot.x11[:status]
      when 'connected' then check('x11', 'ok', "connected to #{@snapshot.x11[:display]}")
      when 'timed_out' then check('x11', 'fail', reason, 'The X server is not answering; check the session.')
      else check('x11', 'warn', reason, 'Run from the desktop session, or set DISPLAY and XAUTHORITY.')
      end
    end

    def input_extension
      extensions = @snapshot.x11[:extensions]
      return check('x11_extensions', 'skip', 'no X11 connection') unless extensions

      missing = extensions.reject { |_, present| present }.keys
      return check('x11_extensions', 'ok', extensions.keys.join(', ')) if missing.empty?

      check('x11_extensions', 'warn', "missing #{missing.join(', ')}")
    end

    def window
      return check('game_window', 'skip', 'the game is not running') unless @snapshot.process

      found = @snapshot.window
      return check('game_window', 'ok', "#{found.hex_id} #{found.width}x#{found.height}") if found

      check('game_window', 'warn', 'no usable window',
            'It appears some seconds after launch. Native Wayland Proton has none.')
    end

    def capture
      found = @snapshot.window
      return check('capture', 'skip', 'no game window to try') unless found && @connection

      problem = Capture::Service.x11_problem(@connection, found)
      problem ? check('capture', 'warn', problem) : check('capture', 'ok', 'X11 returned an image of the window')
    end

    def compositor
      name = @snapshot.compositor.name
      return check('compositor', 'ok', "#{name} #{@snapshot.compositor.version}") if @snapshot.compositor.available?

      check('compositor', 'info', @snapshot.compositor.reason.to_s)
    end

    def dialogs
      status = @snapshot.modals[:status]
      names = @snapshot.modals[:blocking].map { it[:namespace] }.join(', ')
      return check('system_dialogs', 'warn', "a surface is over the game: #{names}") if status == 'present'
      return check('system_dialogs', 'ok', 'none over the game') if status == 'clear'

      check('system_dialogs', 'info', @snapshot.modals[:reason].to_s)
    end
  end
end
