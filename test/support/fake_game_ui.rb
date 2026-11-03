# frozen_string_literal: true

require 'digest'
require 'json'

# A game whose screens are patterns on a small window, driven by the same routes the shipped profile
# has, so a test exercises the real transitions without one pixel of the game. It reacts the way the
# real one was measured to: late, once, and only when the key or the point is right.
class FakeGameUi
  WIDTH = 160
  HEIGHT = 90
  BUILD = '111'
  LANGUAGE = 'english'
  GRID = [4, 2].freeze
  CELL = [16, 8].freeze
  KEY_PRESS = 2
  KEY_RELEASE = 3
  BUTTON_PRESS = 4
  BACKGROUND = 16
  LONG_PRESS = 1.0
  SHIPPED = Cdctl::Recognition::Profile.all.first
  OPTION_FILE = <<~XML
    <EngineOptionSave><EngineOption Name="_option"><Group Name="_controlsOption">%<preset>s<Enum Name="_gamePadPresetOptionType" _select="A"/></Group><Scalar Name="_uiHudScale" _value="90"/><Scalar Name="_upscaleResolution" _select="67%%"/></EngineOption></EngineOptionSave>
  XML
  STANDARD_ELEMENT = '<Enum Name="_keyboardMousePresetOptionType" _select="A"/>'

  attr_accessor :screen, :stall, :deaf, :opened_from, :preset, :on_apply
  attr_reader :machine

  def self.options_text(preset)
    format(OPTION_FILE, preset: preset == 'standard' ? STANDARD_ELEMENT : '')
  end

  def initialize(machine, screen: 'world', preset: 'standard', proc_game: 4242)
    @machine = machine
    @screen = screen
    @preset = preset
    @opened_from = screen == 'title' ? :title : :world
    @proc_game = proc_game
    @stall = 0
    @names = names
    @pending_preset = preset
    @frames = {}
    write_profile
    @window = machine.x_server.windows.fetch(Machine::GAME_WINDOW)
    machine.x_server.on_fake_input = method(:react)
    redraw
  end

  def redraw = @window.pixel = frame_bytes(visible_anchors)

  def show(screen)
    @screen = screen
    redraw
  end

  def anchor_names = SHIPPED.instance_variable_get(:@anchors).keys

  private

  def names = anchor_names.each_with_index.to_h { |name, index| [name, index] }

  def box(index) = [(index % 8) * 20, (index / 8) * 11, CELL.first, CELL.last]

  def write_profile
    path = File.join(Cdctl::Paths.new(machine.env).profiles_dir, 'test.json')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(profile))
  end

  def profile
    { id: 'test', builds: [BUILD], language: LANGUAGE, aspect: [16, 9], hud_scale: 90, ui_scale: 100,
      keyboard_presets: SHIPPED.keyboard_presets, screens: SHIPPED.screens, transitions: SHIPPED.transitions,
      points: SHIPPED.points, flows: SHIPPED.flows, settings: SHIPPED.settings, anchors: anchors }
  end

  def anchors
    @names.to_h do |name, index|
      rect = box(index).map { it.to_f / HEIGHT }
      [name, { rect:, grid: GRID, channel: 'luma', minimum: 0.85, signature: pattern(name) }]
    end
  end

  # Each anchor has a pattern of its own, and each cell is a value from its name.
  def pattern(name)
    Digest::MD5.digest(name).bytes.first(GRID.reduce(:*)).map { it.odd? ? 230 : 25 }
  end

  def visible_anchors
    case screen
    when 'title' then %w[title.copyright title.settings_label title.play.keys]
    when 'world' then %w[world.corner]
    when /\Amenu\.(.+)/ then ["menu.tab.#{Regexp.last_match(1)}"]
    when /\Asettings\.(.+)/ then settings_anchors(Regexp.last_match(1))
    when 'dialog.exit' then %w[dialog.exit.text dialog.exit.prompts menu.tab.others]
    when 'dialog.apply' then %w[dialog.apply.text dialog.apply.prompts settings.restore settings.tab.input]
    else []
    end
  end

  def settings_anchors(tab)
    list = ['settings.restore', "settings.tab.#{tab}"]
    list << 'menu.tab.others' if opened_from == :world
    list << "settings.input.keyboard.#{@pending_preset}" if tab == 'input'
    list
  end

  def frame_bytes(visible)
    @frames[visible] ||= begin
      rows = Array.new(HEIGHT) { Array.new(WIDTH, BACKGROUND) }
      visible.each { paint(rows, it) }
      rows.flatten.map { (it << 16) | (it << 8) | it }.pack('V*')
    end
  end

  def paint(rows, name)
    x0, y0, width, height = box(@names.fetch(name))
    cells = pattern(name)
    height.times do |dy|
      width.times do |dx|
        rows[y0 + dy][x0 + dx] = cells[((dy * GRID.last / height) * GRID.first) + (dx * GRID.first / width)]
      end
    end
  end

  def react(type, detail)
    return if deaf

    case type
    when KEY_PRESS then key_down(detail)
    when KEY_RELEASE then key_up(detail)
    when BUTTON_PRESS then clicked(machine.x_server.pointer) if detail == 1
    end
  end

  def key_name(code)
    keysym = FakeXServer::KEYSYMS[code - FakeXServer::FIRST_KEYCODE]
    { 0xFF1B => 'Escape', 0x20 => 'space' }.fetch(keysym) { keysym.chr }
  end

  def key_down(code)
    @pressed_at = now
    name = key_name(code)
    apply_key(name)
  end

  def key_up(code)
    return if now - @pressed_at.to_f < LONG_PRESS

    name = key_name(code)
    exit_game if (name == 'Escape' && screen == 'title') || (name == 'space' && screen == 'dialog.exit')
  end

  def apply_key(name)
    return apply_confirm if name == 'space'
    return start_world if name == 'e' && screen == 'title'

    edge = SHIPPED.transitions.find { it[:key] == name && it[:from].include?(screen) && context_allows?(it) }
    move_to(edge[:to].first) if edge
    @opened_from = :title if screen == 'title'
  end

  def context_allows?(edge)
    return opened_from == :world if edge[:requires]
    return opened_from == :title if edge[:unless]

    true
  end

  def apply_confirm
    if screen == 'settings.input' && @pending_preset != preset
      move_to('dialog.apply')
    elsif screen == 'dialog.apply'
      apply_preset
    end
  end

  def apply_preset
    self.preset = @pending_preset
    machine.write_options(self.class.options_text(preset), modified_at: Time.now + 1)
    on_apply&.call
    move_to('settings.input')
  end

  def start_world
    @opened_from = :world
    move_to('world')
  end

  def clicked(position)
    name = SHIPPED.points.keys.find { near?(position, SHIPPED.point(it, HEIGHT)) }
    return unless name

    case name.to_s
    when 'settings.input.keyboard.previous' then choose('classic')
    when 'settings.input.keyboard.next' then choose('standard')
    when 'others.settings' then open_settings
    when 'others.quit' then move_to('dialog.exit')
    else via_edge(name.to_s)
    end
  end

  def choose(value)
    @pending_preset = value
    redraw
  end

  def open_settings = move_to('settings.video')

  def via_edge(point)
    edge = SHIPPED.transitions.find { it[:click] == point && it[:from].include?(screen) }
    move_to(edge[:to].first) if edge
  end

  def near?(position, point)
    (position.first - point.first).abs <= 1 && (position.last - point.last).abs <= 1
  end

  def move_to(target)
    return show(target) if stall.zero?

    Thread.new do
      sleep(stall)
      show(target)
    end
  end

  def exit_game = FileUtils.rm_rf(File.join(machine.proc_root, @proc_game.to_s))

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

class Machine
  # A running game with a small window, a compositor proving it is on top, and an option file.
  def game_with_ui(screen: 'world', preset: 'standard')
    start_x(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT) unless x_server
    install_game(steam_root, build: FakeGameUi::BUILD, language: FakeGameUi::LANGUAGE,
                             options: FakeGameUi.options_text(preset))
    run_game
    game_window(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
    hyprland(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT)
    FakeGameUi.new(self, screen:, preset:)
  end
end
