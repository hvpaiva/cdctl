# frozen_string_literal: true

require 'json'
require_relative 'shell'

module Cdctl
  # Optional enrichment from the compositor: the real monitor mode, whether the game is the active
  # window and, where the compositor exposes them, the surfaces drawn over the game. Nothing depends
  # on one being known; each missing answer becomes unknown and is listed as not verified.
  #
  # Of any other window this keeps nothing, not even a title. A title can name a bank or a private
  # document, and every result ends up in a caller's log.
  module Compositor
    State = Data.define(:name, :status, :reason, :version, :monitors, :game_active, :game_client, :overlay_layers,
                        :top_layers, :layers_visible, :locked, :desktop) do
      def self.none(desktop, reason)
        new(name: nil, status: 'none', reason:, version: nil, monitors: [], game_active: nil, game_client: nil,
            overlay_layers: [], top_layers: [], layers_visible: false, locked: nil, desktop:)
      end

      def initialize(desktop: nil, **fields) = super

      def available? = status == 'available'

      # One monitor needs no proof. Among several only the game's own client can say which: focus
      # would name the monitor the person is looking at, and change when they look elsewhere.
      def relevant_monitor
        return monitors.first if monitors.one?

        game_client && monitors.find { it[:id] == game_client[:monitor] }
      end

      def to_h
        { name:, status:, desktop:, version:, reason:, game_active:, game_client:,
          monitor: game_client && relevant_monitor&.fetch(:output, nil) }.compact
      end
    end

    NO_DRIVER = 'no driver for this desktop, so system dialogs cannot be seen'

    def self.observe(shell:, env:, game_pid:)
      hyprland = Hyprland.detect(shell:, env:)
      return hyprland.observe(game_pid:) if hyprland

      State.none(env['XDG_CURRENT_DESKTOP'], NO_DRIVER)
    end

    class Hyprland
      NAME = 'hyprland'
      OVERLAY_LEVEL = '3'
      TOP_LEVEL = '2'
      SIGNATURE_VARIABLE = 'HYPRLAND_INSTANCE_SIGNATURE'
      UNREADABLE = [Shell::NotAvailable, Shell::TimedOut, JSON::ParserError, TypeError, NoMethodError, KeyError].freeze

      # hyprctl answering is the proof of a running compositor; being installed is not.
      def self.detect(shell:, env:)
        output = shell.run('hyprctl', 'instances', '-j')
        return nil unless output.success?

        instances = JSON.parse(output.stdout).map { it['instance'] }
        signature = env[SIGNATURE_VARIABLE]
        chosen = instances.include?(signature) ? signature : (instances.first if instances.one?)
        chosen && new(shell:, instance: chosen)
      rescue Shell::NotAvailable, Shell::TimedOut, JSON::ParserError, TypeError, NoMethodError
        nil
      end

      def initialize(shell:, instance:)
        @shell = shell
        @instance = instance
      end

      def observe(game_pid:)
        active = query('activewindow')
        game_on_top = !game_pid.nil? && active['pid'] == game_pid
        layers = query('layers')
        State.new(
          name: NAME, status: 'available', reason: nil, version: query('version')['tag'], monitors:,
          game_active: game_pid && game_on_top,
          game_client: game_on_top ? window(active) : game_client(game_pid),
          overlay_layers: surfaces(layers, OVERLAY_LEVEL), top_layers: surfaces(layers, TOP_LEVEL),
          layers_visible: true, locked:
        )
      rescue *UNREADABLE => e
        State.new(name: NAME, status: 'unavailable', reason: e.message, version: nil, monitors: [], game_active: nil,
                  game_client: nil, overlay_layers: [], top_layers: [], layers_visible: false, locked: nil)
      end

      private

      def query(topic)
        output = @shell.run('hyprctl', '-i', @instance, '-j', topic)
        raise KeyError, "hyprctl #{topic} failed" unless output.success?

        JSON.parse(output.stdout)
      end

      def monitors
        query('monitors').map do |monitor|
          { id: monitor.fetch('id'), output: monitor.fetch('name'), width: monitor.fetch('width'),
            height: monitor.fetch('height'), refresh_hz: monitor.fetch('refreshRate').to_f.round(3),
            scale: monitor.fetch('scale'), x: monitor.fetch('x'), y: monitor.fetch('y'),
            focused: monitor.fetch('focused') }
        end
      end

      # Called with the game's own client only. See the note on this module.
      def window(client)
        { class: client['class'], title: client['title'], pid: client['pid'], x: client.dig('at', 0),
          y: client.dig('at', 1), width: client.dig('size', 0), height: client.dig('size', 1),
          monitor: client['monitor'], workspace: client.dig('workspace', 'name'), fullscreen: client['fullscreen'] }
      end

      def game_client(pid)
        return nil unless pid

        found = query('clients').find { it['pid'] == pid }
        found && window(found)
      end

      def surfaces(layers, level)
        layers.flat_map do |output, content|
          content.fetch('levels').fetch(level, []).map do |layer|
            { namespace: layer['namespace'], output:, x: layer['x'], y: layer['y'], width: layer['w'],
              height: layer['h'] }
          end
        end
      end

      # A compositor without this query says nothing, which differs from saying it is not locked.
      def locked
        query('locked')['locked']
      rescue *UNREADABLE
        nil
      end
    end
  end
end
