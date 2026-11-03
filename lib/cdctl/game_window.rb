# frozen_string_literal: true

module Cdctl
  GameWindow = Data.define(:id, :title, :wm_class, :pid, :x, :y, :width, :height, :depth, :visual, :viewable,
                           :focused, :states, :children, :evidence) do
    def hex_id = format('0x%x', id)

    def fullscreen? = states.include?('_NET_WM_STATE_FULLSCREEN')

    def hidden? = states.include?('_NET_WM_STATE_HIDDEN')

    def center = [x + (width / 2), y + (height / 2)]

    def to_h
      { state: 'found', id: hex_id, title:, class: wm_class, pid:, x:, y:, width:, height:, depth:, viewable:,
        focused:, fullscreen: fullscreen?, hidden: hidden?, evidence:, children: }
    end
  end

  # Finds the game's window on one X server. Every property is a separate piece of evidence, so a
  # sandbox that hides the PID or a build that drops a property narrows the proof without losing
  # the window, and the evidence list says what held.
  class WindowFinder
    # Wine creates tiny helper windows that are never the game.
    MIN_SIZE = 64
    MAX_TREE_DEPTH = 3
    MAX_FOCUS_WALK = 32
    MAX_CHILDREN = 8

    def initialize(connection, app_id:, window_class:, pid: nil)
      @connection = connection
      @app_id = app_id
      @window_class = window_class
      @pid = pid
    end

    # Every viewable window of the game. More than one means the caller must not pick.
    def candidates
      toplevels.filter_map { inspect_window(it) }.select(&:viewable).select do |window|
        window.width >= MIN_SIZE && window.height >= MIN_SIZE
      end
    end

    private

    def toplevels
      listed = @connection.property_numbers(root, '_NET_CLIENT_LIST')
      listed.empty? ? walk(root, MAX_TREE_DEPTH) : listed
    end

    def root = @connection.screen.root

    def walk(window, depth)
      children = @connection.tree(window).children
      return children if depth <= 1

      children + children.flat_map { walk(it, depth - 1) }
    rescue X11::RequestError
      []
    end

    # A window can close between listing and reading it.
    def inspect_window(id)
      wm_class = @connection.property_text(id, 'WM_CLASS').to_s.split("\0")
      pid = @connection.property_numbers(id, '_NET_WM_PID').first
      evidence = evidence_for(id, wm_class, pid)
      evidence.empty? ? nil : build(id, wm_class, pid, evidence)
    rescue X11::RequestError
      nil
    end

    def evidence_for(id, wm_class, pid)
      marks = []
      marks << 'steam_game_property' if @connection.property_numbers(id, 'STEAM_GAME').first == @app_id
      marks << 'wm_class' if wm_class.include?(@window_class)
      marks << 'net_wm_pid' if @pid && pid == @pid
      marks
    end

    def build(id, wm_class, pid, evidence)
      geometry = @connection.geometry(id)
      attributes = @connection.attributes(id)
      x, y = @connection.position_on_root(id)
      GameWindow.new(
        id:, title: title(id), wm_class:, pid:, x:, y:, width: geometry.width, height: geometry.height,
        depth: geometry.depth, visual: attributes.visual, viewable: attributes.viewable?, focused: focused?(id),
        states: states(id), children: children(id), evidence:
      )
    end

    def title(id)
      @connection.property_text(id, '_NET_WM_NAME') || @connection.property_text(id, 'WM_NAME')
    end

    def states(id)
      @connection.property_numbers(id, '_NET_WM_STATE').map { @connection.atom_name(it) }
    end

    # Wine draws into a child window; its size is kept as evidence for the resolution model. Wine
    # also creates and destroys children at will, and one that vanishes says nothing about the game.
    def children(id)
      @connection.tree(id).children.first(MAX_CHILDREN).filter_map { child(it) }
    end

    def child(id)
      geometry = @connection.geometry(id)
      { id: format('0x%x', id), x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height }
    rescue X11::RequestError
      nil
    end

    # The focus can belong to any program and be gone by the time its parents are asked for, which
    # proves only that this window does not have it.
    def focused?(id)
      current = @connection.input_focus
      return false if [X11::Requests::NO_FOCUS, X11::Requests::POINTER_ROOT_FOCUS].include?(current)

      MAX_FOCUS_WALK.times do
        return true if current == id
        return false if current == root || current.zero?

        current = @connection.tree(current).parent
      end
      false
    rescue X11::RequestError
      false
    end
  end
end
