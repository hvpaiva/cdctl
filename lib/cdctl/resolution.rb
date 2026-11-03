# frozen_string_literal: true

require_relative 'fact'

module Cdctl
  # Every number that gets called "the resolution", kept apart, because they disagree in practice:
  # a window can stay at the monitor's size while the game renders a smaller image stretched to
  # fill it, a nested compositor can show the game a screen the monitor does not have, and an
  # upscaler renders below whatever the settings menu says.
  class Resolution
    ACTIVE_UNKNOWN = 'the game does not publish this; it can only be read from its video menu, for this process'
    NOT_RUNNING = 'the game is not running'
    NO_CAPTURE = 'this command took no capture'
    NO_LEDGER = 'nothing is known about the display at an earlier moment'
    FIRST_LOOK = 'this is the first observation of this process, so its display mode at launch is unknown'
    NOT_COMPARABLE = 'the display was not read the same way both times, so a change cannot be detected'
    NOT_LAUNCHED_HERE = 'the game was not launched through cdctl'
    DISPLAY_CHANGED = 'the display changed after this process was first seen'
    FILE_NEWER = 'the option file may have changed after this process started, so it may not describe this process'
    # The game may adopt the screen at launch, but a mode changed since then leaves a window that
    # fills the screen around an image of the old size, so a matching size proves nothing.
    NOTHING_STORED = 'the file stores no resolution, so the game chose one at launch, and cdctl did not launch it'

    # `witness` is the display as far as it can be read here, or nil where nothing can see it.
    def initialize(window:, screen:, display:, options:, nested:, baseline:, witness:, started_at:)
      @window = window
      @screen = screen
      @display = display
      @options = options
      @nested = nested
      @baseline = baseline
      @witness = witness
      @started_at = started_at
    end

    def to_h
      {
        display_mode: @display, game_screen: @screen, window: window_fact, capture: Fact.unknown(NO_CAPTURE),
        configured_override: option(:viewport_size), active: Fact.unknown(ACTIVE_UNKNOWN),
        render_scale: option(:upscale_resolution), hud_scale: option(:hud_scale),
        presentation:, launch_display_mode:, coherence:, first_seen: @baseline&.first_seen
      }.compact
    end

    def coherence
      return Fact.unknown(NOT_RUNNING) unless @window
      return Fact.unknown(NO_LEDGER) unless @baseline
      return Fact.unknown(FIRST_LOOK) if @baseline.fresh?
      return Fact.unknown(NOT_COMPARABLE) unless @baseline.comparable?(@witness)

      changes = @baseline.differences(window: size(@window), display: @witness)
      Fact.known({ state: coherence_state(changes), since: 'first_seen', changes: }, source: 'cdctl_ledger')
    end

    private

    def launch_display_mode
      launch = @baseline&.launch_display
      launch ? Fact.known(launch, source: 'cdctl_launch') : Fact.unknown(NOT_LAUNCHED_HERE)
    end

    # A window alone can change with the display untouched: a splash becomes the game, or the person
    # resizes it. Only a display change is known to damage the image.
    def coherence_state(changes)
      return 'consistent' if changes.empty?

      changes.any? { it[:field] == :display } ? 'display_changed' : 'window_changed'
    end

    def window_fact
      return Fact.unknown(NOT_RUNNING) unless @window

      Fact.known({ x: @window.x, y: @window.y, width: @window.width, height: @window.height }, source: 'x11')
    end

    def option(name)
      return @options.public_send(name) if @options.respond_to?(name)

      Fact.unknown(@options.to_s)
    end

    def presentation
      return Fact.unknown(NOT_RUNNING) unless @window
      return Fact.known({ mode: 'nested' }, source: 'process_tree') if @nested
      return Fact.unknown(DISPLAY_CHANGED) if display_changed?

      override = option(:viewport_size)
      return Fact.unknown("the option file could not be read: #{override.reason}") unless override.known?
      return Fact.unknown(FILE_NEWER) if file_newer_than_process?

      from_override(override.value)
    end

    def from_override(override)
      return from_launch unless override
      return inferred(mode: 'native') if size(@window) == override

      inferred(mode: 'stretched', rendered: override, scale_x: ratio(@window.width, override[:width]),
               scale_y: ratio(@window.height, override[:height]))
    end

    # With nothing stored the game takes the display at launch, and cdctl saw that moment only if it
    # launched the game. The window then matching that display says the image fills it one to one.
    def from_launch
      launch = @baseline&.launch_display
      return Fact.unknown(NOTHING_STORED) unless launch
      return inferred(mode: 'native') if launch.slice(:width, :height) == size(@window)

      Fact.unknown('the window does not match the display at launch, and nothing says what the image is')
    end

    def inferred(**value) = Fact.known(value, source: 'option_file+x11', confidence: 'inferred')

    def file_newer_than_process?
      @started_at.nil? || @options.modified_at > @started_at
    end

    def display_changed?
      fact = coherence
      fact.known? && fact.value[:state] == 'display_changed'
    end

    def size(window) = { width: window.width, height: window.height }

    def ratio(outer, inner) = (outer.to_f / inner).round(5)
  end
end
