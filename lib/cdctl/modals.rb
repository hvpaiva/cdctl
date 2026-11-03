# frozen_string_literal: true

module Cdctl
  # Whether a system dialog may be over the game. The rule names no dialog: every surface on the
  # overlay layer counts unless it matches an ignore pattern, because an authentication prompt
  # from an unknown desktop shell must stop automation just like a known one.
  #
  # "clear" is a claim, so it needs proof. A prompt can also be an ordinary window, which only shows
  # as another window being active, and a surface on the top layer can sit over a game that is not
  # fullscreen. Neither can be told from a dialog without reading another program's window, so both
  # answer "unverified".
  module Modals
    UNAVAILABLE = 'this compositor does not expose the surfaces drawn over the game'
    NOT_ACTIVE = 'another window is active and it may be a dialog; cdctl does not read what it is'
    LOCK_UNKNOWN = 'this compositor does not say whether the session is locked'
    SESSION_LOCK = 'session_lock'
    # How a compositor writes a fullscreen client: a mode number, or a boolean in older versions. A
    # fullscreen window hides the top layer, measured by comparing captures of the screen and the window.
    FULLSCREEN = [2, 3, true].freeze

    module_function

    def assess(compositor, ignored:, pid: nil)
      unless compositor.layers_visible
        return { status: 'unavailable', reason: compositor.reason || UNAVAILABLE, blocking: [], ignored: [] }
      end

      skipped, blocking = sized(compositor.overlay_layers).partition { |layer| ignored?(layer[:namespace], ignored) }
      blocking += [{ namespace: SESSION_LOCK }] if compositor.locked
      report = { source: "#{compositor.name}_layers", blocking:, ignored: skipped }
      return { status: 'present', **report } unless blocking.empty?

      reason = doubt(compositor, pid, ignored)
      reason ? { status: 'unverified', reason:, **report } : { status: 'clear', **report }
    end

    def overlap?(one, other)
      one[:x].to_i < other[:x].to_i + other[:width].to_i && other[:x].to_i < one[:x].to_i + one[:width].to_i &&
        one[:y].to_i < other[:y].to_i + other[:height].to_i && other[:y].to_i < one[:y].to_i + one[:height].to_i
    end

    def doubt(compositor, pid, ignored)
      return LOCK_UNKNOWN if compositor.locked.nil?
      return nil unless pid
      return NOT_ACTIVE unless compositor.game_active

      covering = surfaces_over_the_game(compositor, ignored)
      "surfaces on the top layer overlap the game: #{covering.join(', ')}" unless covering.empty?
    end
    private_class_method :doubt

    def surfaces_over_the_game(compositor, ignored)
      client = compositor.game_client
      return [] if client.nil? || FULLSCREEN.include?(client[:fullscreen])

      sized(compositor.top_layers).filter_map do |layer|
        layer[:namespace] if overlap?(layer, client) && !ignored?(layer[:namespace], ignored)
      end
    end
    private_class_method :surfaces_over_the_game

    def sized(layers) = layers.select { it[:width].to_i.positive? && it[:height].to_i.positive? }
    private_class_method :sized

    def ignored?(namespace, patterns)
      patterns.any? { File.fnmatch?(it, namespace.to_s, File::FNM_CASEFOLD) }
    end
    private_class_method :ignored?
  end
end
