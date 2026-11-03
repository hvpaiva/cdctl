# frozen_string_literal: true

require_relative 'error'
require_relative 'fact'
require_relative 'game'
require_relative 'platform'

module Cdctl
  # Everything one look at the machine found, including what it could not find. Read-only commands
  # report it as it is; commands that need the game call require_window! and fail with a reason.
  Snapshot = Data.define(:observed_at, :platform, :steam, :installation, :scan, :x11, :windows, :compositor, :modals,
                         :options_path, :options, :resolution, :version) do
    def process = scan&.processes&.one? ? scan.processes.first : nil

    def window = windows&.one? ? windows.first : nil

    def linux? = platform == Platform::LINUX

    def require_window!
      refuse_platform unless linux?
      refuse_process
      refuse_window
      window
    end

    # An authentication prompt stops everything that looks at the screen. The X11 backend would not
    # show it, but the person has a decision to make, and a caller that keeps working hides it.
    def require_capturable!
      found = require_window!
      refuse_dialog
      found
    end

    def require_no_timeout!
      return unless timed_out?

      raise Error.new("the X server did not answer: #{x11[:reason]}", code: 'TIMEOUT', data: to_h, target:,
                                                                      next_steps: ['Run cdctl doctor.'])
    end

    def target
      return nil unless process

      { pid: process.pid, start_ticks: process.start_ticks, window: window&.hex_id, observed_at: observed_at }.compact
    end

    # The comparison base for later actions: what must stay equal for a coordinate to keep its
    # meaning. The same window can hold another layout after a stored resolution or a HUD scale
    # changes, so those count as much as its size.
    def fingerprint
      return nil unless process && window

      {
        boot: process.boot_id, pid: process.pid, start_ticks: process.start_ticks, window: window.hex_id,
        x: window.x, y: window.y, width: window.width, height: window.height, **layout_fingerprint
      }
    end

    def not_verified
      list = ['game.active_resolution', 'game.screen']
      list << 'display_mode' unless resolution[:display_mode].known?
      list << 'game.stored_resolution' unless resolution[:configured_override].known?
      list << 'system_dialogs' if %w[unavailable unverified].include?(modals[:status])
      list
    end

    def with_capture(artifact)
      fact = Fact.known({ width: artifact[:width], height: artifact[:height] }, source: artifact[:backend],
                                                                                observed_at: artifact[:captured_at])
      with(resolution: resolution.merge(capture: fact))
    end

    def to_h
      {
        observed_at:, platform: { os: platform, ruby: RUBY_VERSION }, installation: installation_report,
        game: game_report, x11:, window: window_report, compositor: compositor.to_h, modals:,
        resolution:, settings: settings_report
      }
    end

    private

    def timed_out? = x11[:status] == 'timed_out'

    def layout_fingerprint
      {
        display: slice_of(resolution[:display_mode], :output, :width, :height, :scale),
        screen: slice_of(resolution[:game_screen], :output, :x, :y, :width, :height),
        stored_resolution: resolution[:configured_override].value, hud_scale: resolution[:hud_scale].value
      }
    end

    def slice_of(fact, *keys) = fact.known? ? fact.value.slice(*keys) : nil

    def installation_report
      return installation.to_h.merge(version:) if installation

      count = steam.installations.size
      { state: count > 1 ? 'ambiguous' : 'not_found', searched: steam.searched, steam_roots: steam.roots,
        libraries_with_game: steam.installations.map(&:library), problems: steam.problems }
    end

    def game_report
      return { state: 'unsupported', reason: "process discovery is not available on #{platform}" } unless scan
      return { state: 'unknown', reason: scan.problem } if scan.problem
      return process.to_h.merge(state: 'running') if process
      return { state: 'ambiguous', candidates: scan.processes.map(&:pid) } if scan.processes.size > 1

      { state: scan.launching ? 'starting_or_closing' : 'not_running' }
    end

    def window_report
      return window.to_h if window
      return { state: 'ambiguous', candidates: windows.map(&:to_h) } if windows&.size.to_i > 1
      return { state: 'not_applicable' } unless process
      return { state: 'unknown', reason: x11[:reason] } unless x11[:status] == 'connected'

      { state: 'not_found' }
    end

    def settings_report
      return { file: options_path, state: 'unavailable', reason: options.to_s } unless options.respond_to?(:path)

      { file: options.path, state: 'read', modified_at: options.modified_at.iso8601,
        keyboard_mouse_preset_raw: options.keyboard_mouse_preset }
    end

    def refuse_platform
      raise Error.new("observing the game is not supported on #{platform} yet",
                      code: 'UNSUPPORTED_PLATFORM', data: to_h,
                      next_steps: ['Run cdctl capabilities to see what works on this machine.'])
    end

    def refuse_process
      return if process

      raise Error.new(scan.problem, code: 'PRECONDITION_FAILED', data: to_h) if scan.problem

      count = scan.processes.size
      if count > 1
        raise Error.new("#{count} processes match the game; cdctl will not pick one", code: 'TARGET_AMBIGUOUS',
                                                                                      data: to_h)
      end

      raise Error.new('the game is not running', code: 'GAME_NOT_RUNNING', data: to_h,
                                                 next_steps: ['Start the game from Steam, then run cdctl status.'])
    end

    def refuse_window
      return if window

      require_no_timeout!
      count = windows.to_a.size
      if count > 1
        raise Error.new("#{count} windows match the game; cdctl will not pick one",
                        code: 'TARGET_AMBIGUOUS', data: to_h, target:)
      end

      raise Error.new(missing_window_reason, code: 'WINDOW_NOT_FOUND', data: to_h, target:,
                                             next_steps: ['Wait for the window, or run cdctl doctor.'])
    end

    def missing_window_reason
      return 'the game has no visible window yet' if x11[:status] == 'connected'

      "X11 is not reachable: #{x11[:reason]}"
    end

    def refuse_dialog
      return unless modals[:status] == 'present'

      names = modals[:blocking].map { it[:namespace] }.join(', ')
      raise Error.new("a system surface is over the game and may be asking for authentication: #{names}",
                      code: 'SYSTEM_DIALOG_PRESENT', data: to_h, target:, next_steps: [
                        'Tell the person using this machine. Never answer, dismiss or work around it.',
                        'If this surface is never a dialog, add it to ignored_overlay_layers in the configuration file.'
                      ])
    end
  end
end
