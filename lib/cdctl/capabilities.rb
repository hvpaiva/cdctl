# frozen_string_literal: true

require_relative 'capture/ppm'
require_relative 'capture/service'
require_relative 'error_codes'
require_relative 'shell'
require_relative 'x11'

module Cdctl
  # What this cdctl can do on this machine, proven by trying it where trying is harmless. A program
  # being installed proves nothing: grim must return a pixel and X11 must return an image, and with
  # nothing to try a capability on, the answer is unverified rather than available.
  class Capabilities
    # The setups tried against the real game, recorded in docs/test-matrix.md.
    TESTED_COMPOSITORS = %w[hyprland].freeze

    PLANNED = [
      ['game.launch', %w[game launch], 'Start the game through Steam and wait for it'],
      ['game.continue', %w[game continue], 'Continue the saved game from the title screen'],
      ['game.quit', %w[game quit], 'Quit through the game menu and confirm the process ended'],
      ['menu.open', %w[menu open], 'Reach a menu and verify it, without toggling it closed'],
      ['settings.set', %w[settings set], 'Change one setting through the menu and verify it'],
      ['diagnostics.performance', %w[diagnostics], 'Frame time, VRAM and logs with sources']
    ].freeze

    def initialize(snapshot:, connection:, shell:)
      @snapshot = snapshot
      @connection = connection
      @shell = shell
    end

    def to_h
      { environment:, capabilities: capabilities.map(&:compact), error_codes: ErrorCodes.catalog,
        exit_statuses: ErrorCodes.exit_statuses.transform_keys(&:to_s) }
    end

    private

    def environment
      name = @snapshot.compositor.name
      tested = x11_connected? && @snapshot.linux? && TESTED_COMPOSITORS.include?(name) && !@snapshot.process&.nested?
      { platform: @snapshot.platform, compositor: name, x11: x11_connected?,
        validation: tested ? 'tested_with_the_game' : 'not_tested_with_the_game' }
    end

    def x11_connected? = @snapshot.x11[:status] == 'connected'

    def capabilities
      [discovery, build, process, window, resolution, modals, capture_x11, capture_grim, option_file, screen, lease,
       input, watching_input, *planned, hud]
    end

    # Proving this would mean sending something to the game, which nothing here may do on its own.
    def input
      id = 'input'
      summary = 'Send guarded keys, clicks and wheel turns, with a guaranteed release'
      commands = ['input key', 'input click', 'input move', 'input scroll', 'input release']
      return unsupported(id, summary) unless @snapshot.linux?
      return entry(id, 'unavailable', summary, commands, @snapshot.x11[:reason]) unless x11_connected?
      unless @snapshot.x11.dig(:extensions, 'XTEST')
        return entry(id, 'unavailable', summary, commands, 'this X server has no XTEST extension')
      end

      entry(id, 'unverified', summary, commands, 'not tried here, because trying means sending input to the game')
    end

    def watching_input
      id = 'input.other_sources'
      summary = 'Notice input from a person or another program during a send, by device and never by key'
      return unsupported(id, summary) unless @snapshot.linux?

      seen = x11_connected? && @snapshot.x11.dig(:extensions, 'XInputExtension')
      if seen
        entry(id, 'available', summary,
              ['input key'])
      else
        entry(id, 'unavailable', summary, [], 'no XInput on this server')
      end
    end

    def lease
      entry('lease', 'available', 'Exclusive ownership of input between programs', ['lease status', 'lease acquire',
                                                                                    'lease renew', 'lease release'])
    end

    def entry(id, state, summary, commands, reason = nil)
      { id:, state:, summary:, commands:, reason: }
    end

    def discovery
      roots = @snapshot.steam.roots
      state = roots.empty? ? 'unavailable' : 'available'
      entry('discovery.steam', state, 'Find Steam, its libraries and the game', %w[status doctor],
            roots.empty? ? 'no Steam directory was found; set CDCTL_STEAM_ROOT if it is elsewhere' : nil)
    end

    def build
      found = @snapshot.installation
      entry('discovery.build', found ? 'available' : 'unavailable', 'Read the build, version, language and Proton',
            %w[status], found ? nil : 'the game installation was not found')
    end

    def process
      id = 'observe.process'
      summary = 'Find the real game process'
      return unsupported(id, summary) unless @snapshot.linux?

      problem = @snapshot.scan.problem
      return entry(id, 'unavailable', summary, %w[status], problem) if problem
      return entry(id, 'available', summary, %w[status]) if @snapshot.process

      entry(id, 'unverified', summary, %w[status], 'no game process to try')
    end

    def window
      id = 'observe.window'
      summary = 'Find the game window and its geometry'
      return unsupported(id, summary) unless @snapshot.linux?
      return entry(id, 'unavailable', summary, %w[status observe], @snapshot.x11[:reason]) unless x11_connected?
      return entry(id, 'available', summary, %w[status observe]) if @snapshot.window

      entry(id, 'unverified', summary, %w[status observe], 'no game window to try')
    end

    def resolution
      id = 'observe.resolution'
      summary = 'Report display, window, option file and presentation separately'
      return unsupported(id, summary) unless @snapshot.linux?
      return entry(id, 'available', summary, %w[status observe]) if @snapshot.window

      entry(id, 'unverified', summary, %w[status observe], 'no game window to read it from')
    end

    def modals
      seen = @snapshot.modals[:status] != 'unavailable'
      entry('observe.system_dialogs', seen ? 'available' : 'unavailable', 'See surfaces drawn over the game',
            %w[status observe], seen ? nil : @snapshot.modals[:reason])
    end

    def capture_x11
      summary = 'Capture the game window through X11'
      return unsupported('capture.x11_window', summary) unless @snapshot.linux?

      target = @snapshot.window
      unless target && @connection
        return entry('capture.x11_window', 'unverified', summary, %w[screenshot observe], 'no game window to try')
      end

      problem = Capture::Service.x11_problem(@connection, target)
      entry('capture.x11_window', problem ? 'unavailable' : 'available', summary, %w[screenshot observe], problem)
    end

    def capture_grim
      id = 'capture.grim'
      summary = 'Capture through grim on wlroots compositors, only while the game is on top'
      return unsupported(id, summary) unless @snapshot.linux?

      unless @snapshot.compositor.available?
        return entry(id, 'unavailable', summary, %w[screenshot],
                     'it needs a compositor driver to prove the game is on top')
      end

      return entry(id, 'unverified', summary, %w[screenshot], 'not tried while a dialog is present') if dialog_present?

      try_grim(id, summary)
    end

    def dialog_present? = @snapshot.modals[:status] == 'present'

    def try_grim(id, summary)
      output = @shell.run('grim', '-t', 'ppm', '-g', '0,0 1x1', '-')
      raise Shell::NotAvailable, output.stderr.strip unless output.success?

      Capture::Ppm.parse(output.stdout)
      entry(id, 'available', summary, %w[screenshot])
    rescue Shell::NotAvailable, Shell::TimedOut, Capture::Ppm::ParseError => e
      entry(id, 'unavailable', summary, %w[screenshot], e.message)
    end

    def option_file
      summary = 'Read values the game stores in its option file'
      return entry('settings.read_file', 'observe_only', summary, %w[status]) if @snapshot.options.respond_to?(:path)

      entry('settings.read_file', 'unavailable', summary, %w[status], @snapshot.options.to_s)
    end

    def screen
      entry('observe.screen', 'not_implemented', 'Recognize the current screen', %w[observe],
            'no UI profile exists yet, so observe returns an image and screen unknown')
    end

    def planned
      PLANNED.map do |id, words, summary|
        entry(id, 'not_implemented', summary, [words.join(' ')])
      end
    end

    def hud
      entry('hud.radar', 'mod_dependent', 'Observe and set a HUD mod radar', %w[hud],
            'exists only with an identified mod and a validated profile; not implemented')
    end

    def unsupported(id, summary)
      entry(id, 'unsupported', summary, [], "not available on #{@snapshot.platform}")
    end
  end
end
