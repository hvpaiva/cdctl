# frozen_string_literal: true

require 'test_helper'

class SignatureTest < Minitest::Test
  SIGNATURE = Cdctl::Recognition::Signature
  FRAME = Cdctl::Capture::Frame

  # Left half one color and right half another, in the byte order given.
  def split_frame(left, right, layout: :rgb, width: 8, height: 4)
    bytes = Array.new(height) { Array.new(width) { |x| x < width / 2 ? left : right } }.flatten(1).flat_map do |r, g, b|
      layout == :rgb ? [r, g, b] : [b, g, r, 0]
    end
    FRAME.new(width:, height:, layout:, pixels: bytes.pack('C*'))
  end

  def test_a_grid_averages_each_cell
    frame = split_frame([100, 100, 100], [200, 200, 200])

    assert_equal [100, 200], SIGNATURE.of(frame, [0, 0, 8, 4], [2, 1], 'luma')
  end

  def test_both_byte_layouts_read_the_same
    rgb = split_frame([200, 50, 20], [10, 40, 90])
    bgrx = split_frame([200, 50, 20], [10, 40, 90], layout: :bgrx)

    assert_equal SIGNATURE.of(rgb, [0, 0, 8, 4], [2, 2], 'luma'), SIGNATURE.of(bgrx, [0, 0, 8, 4], [2, 2], 'luma')
    assert_equal SIGNATURE.of(rgb, [0, 0, 8, 4], [2, 2], 'warm'), SIGNATURE.of(bgrx, [0, 0, 8, 4], [2, 2], 'warm')
  end

  def test_warm_sees_gold_and_not_white
    gold = split_frame([230, 190, 90], [20, 20, 20])
    white = split_frame([230, 230, 230], [20, 20, 20])

    assert_operator SIGNATURE.of(gold, [0, 0, 8, 4], [2, 1], 'warm').first, :>, 100
    assert_equal 0, SIGNATURE.of(white, [0, 0, 8, 4], [2, 1], 'warm').first
  end

  def test_the_same_shape_correlates_whatever_the_brightness
    assert_in_delta 1.0, SIGNATURE.correlation([10, 200, 10, 200], [60, 120, 60, 120]), 0.001
  end

  def test_the_opposite_shape_correlates_negatively
    assert_in_delta(-1.0, SIGNATURE.correlation([10, 200, 10, 200], [200, 10, 200, 10]), 0.001)
  end

  def test_a_flat_grid_correlates_with_nothing
    assert_in_delta 0.0, SIGNATURE.correlation([50, 50, 50, 50], [10, 200, 10, 200]), 0.001
    assert_in_delta 0.0, SIGNATURE.correlation([10, 200, 10, 200], [50, 50, 50, 50]), 0.001
  end

  # Correlation scales noise up to full contrast, so a nearly black frame could match any label.
  def test_noise_on_a_nearly_black_frame_correlates_with_nothing
    label = [10, 200, 10, 200, 200, 10, 200, 10]
    noise = [0, 2, 0, 2, 2, 0, 2, 0]

    assert_in_delta 0.0, SIGNATURE.correlation(label, noise), 0.001
    assert_in_delta 0.0, SIGNATURE.correlation(noise, label), 0.001
  end

  def test_grids_that_cannot_be_compared_score_zero
    assert_in_delta 0.0, SIGNATURE.correlation([1, 2], [1, 2, 3]), 0.001
    assert_in_delta 0.0, SIGNATURE.correlation([], []), 0.001
  end
end

class ProfileTest < Minitest::Test
  PROFILE = Cdctl::Recognition::Profile

  def setup = @shipped = PROFILE.all.first

  def find(**) = PROFILE.find(build: '26361232', language: 'brazilian', width: 1600, height: 900, **)

  def test_the_shipped_profile_loads
    assert_equal ['26361232'], @shipped.builds
    assert_includes @shipped.screen_names, 'world'
    assert_includes @shipped.keyboard_presets, 'A'
  end

  # A cell this large holds an average of many pixels, so no letter or icon can be read back from it.
  def test_the_shipped_profile_holds_no_pixels_of_the_game
    smallest_cell = 5 / 1080.0
    data = JSON.parse(File.read(File.join(PROFILE::DIRECTORY, 'build-26361232-brazilian-16x9.json')),
                      symbolize_names: true)
    data[:anchors].each do |name, anchor|
      assert_equal anchor[:grid].reduce(:*), anchor[:signature].size, name
      assert_operator anchor[:rect][2] / anchor[:grid].first, :>=, smallest_cell, name
      assert_operator anchor[:rect][3] / anchor[:grid].last, :>=, smallest_cell, name
    end
  end

  def test_every_route_of_the_shipped_profile_names_something_known
    names = @shipped.screen_names
    @shipped.transitions.each do |edge|
      assert_empty((edge[:from] + edge[:to]) - names, edge.inspect)
      assert_includes @shipped.points.keys, edge[:click].to_sym, edge.inspect if edge[:click]
    end
  end

  def test_every_screen_of_the_shipped_profile_has_anchors_that_exist
    @shipped.screens.each { |screen| screen[:anchors].each { assert @shipped.anchor_named(it) } }
  end

  def test_a_covered_game_finds_its_profile_at_any_size_of_that_aspect
    [[1600, 900], [640, 360], [3840, 2160]].each do |width, height|
      assert_equal @shipped.id, find(width:, height:).first&.id, "#{width}x#{height}"
    end
  end

  def test_each_miss_says_why
    assert_includes find(build: '1').last, 'build 1'
    assert_includes find(language: 'english').last, 'english'
    assert_includes find(width: 1000, height: 1000).last, '1000x1000'
    assert_nil find(build: '1').first
  end

  def test_a_point_scales_with_the_window
    x, y = @shipped.point('menu.tab.map', 2160)

    assert_equal(@shipped.points[:'menu.tab.map'].map { (it * 2160).round }, [x, y])
  end

  def test_a_file_that_cannot_be_read_is_skipped
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'broken.json'), 'not json')
      File.write(File.join(directory, 'incomplete.json'), '{"id":"x"}')

      assert_equal [@shipped.id], PROFILE.all(directory).map(&:id)
    end
  end

  def test_a_profile_from_this_machine_comes_first
    Dir.mktmpdir do |directory|
      taught = JSON.parse(File.read(File.join(PROFILE::DIRECTORY, 'build-26361232-brazilian-16x9.json')))
      File.write(File.join(directory, 'taught.json'), JSON.generate(taught.merge('id' => 'taught')))

      assert_equal 'taught', PROFILE.all(directory).first.id
    end
  end

  def test_a_missing_directory_is_no_problem
    assert_equal [@shipped.id], PROFILE.all('/nonexistent/place').map(&:id)
  end
end

class RecognizerTest < Minitest::Test
  def setup
    @machine = Machine.new
    @ui = @machine.game_with_ui
    @profile = Cdctl::Recognition::Profile.load(File.join(Cdctl::Paths.new(@machine.env).profiles_dir, 'test.json'))
    @connection = @machine.x_server.opener.call(@machine.x_server.display)
  end

  def teardown
    @connection.close
    @machine.destroy
  end

  def frame
    image = @connection.image(Machine::GAME_WINDOW, 0, 0, FakeGameUi::WIDTH, FakeGameUi::HEIGHT)
    Cdctl::Capture::Frame.new(width: FakeGameUi::WIDTH, height: FakeGameUi::HEIGHT, layout: :bgrx, pixels: image.data)
  end

  def recognize(**) = Cdctl::Recognition::Recognizer.new(@profile, **).recognize(frame)&.name

  def test_each_screen_is_told_from_all_the_others
    @profile.screen_names.reject { it == 'dialog.apply' }.each do |name|
      @ui.show(name)

      assert_equal name, recognize, name
    end
  end

  def test_a_dialog_is_named_before_what_it_covers
    @ui.show('dialog.exit')

    assert_equal 'dialog.exit', recognize
    assert @profile.anchor_named('menu.tab.others').matches?(frame)
  end

  def test_nothing_known_on_the_screen_is_an_answer
    @ui.show('loading')

    assert_nil recognize
  end

  def test_a_match_reports_its_score_and_anchors
    match = Cdctl::Recognition::Recognizer.new(@profile).recognize(frame)

    assert_equal 'world', match.to_h[:name]
    assert_in_delta 1.0, match.to_h[:score], 0.01
    assert_equal ['world.corner'], match.to_h[:anchors].keys
  end

  def test_a_screen_known_by_the_hud_needs_the_scale_it_was_measured_with
    assert_equal 'world', recognize(hud_scale: 90)
    assert_nil recognize(hud_scale: 120)
    assert_equal 'world', recognize(hud_scale: nil)

    @ui.show('title')

    assert_equal 'title', recognize(hud_scale: 120)
  end
end

class ObserveScreenTest < Minitest::Test
  include SchemaAssertions

  def setup = @machine = Machine.new
  def teardown = @machine.destroy

  def test_observe_names_the_screen
    ui = @machine.game_with_ui
    ui.show('menu.map')
    status, result, = @machine.run_json('observe')

    assert_equal 0, status
    assert_equal 'menu.map', result[:data][:screen][:value][:name]
    assert_equal 'visual_anchors', result[:data][:screen][:source]
    assert_empty result[:next_steps]
    refute_includes result[:not_verified], 'game.screen'
    assert_valid 'observe', result
  end

  def test_observe_says_so_when_nothing_known_is_on_the_screen
    @machine.game_with_ui.show('loading')
    _, result, = @machine.run_json('observe')

    assert_equal 'unknown', result[:data][:screen][:status]
    assert_includes result[:data][:screen][:reason], 'loading'
    assert_includes result[:not_verified], 'game.screen'
    refute_empty result[:next_steps]
  end

  def test_observe_without_a_profile_still_works_and_says_why
    @machine.full_game
    @machine.hyprland
    status, result, = @machine.run_json('observe')

    assert_equal 0, status
    assert_equal 'unknown', result[:data][:screen][:status]
    assert_includes result[:data][:screen][:reason], 'build 111'
  end

  def test_human_output_names_the_screen
    @machine.game_with_ui
    _, out, = @machine.run('observe')

    assert_match(/Screen\s+world/, out)
  end

  def test_capabilities_follow_the_profile
    @machine.game_with_ui
    _, result, = @machine.run_json('capabilities')
    states = result[:data][:capabilities].to_h { [it[:id], it[:state]] }

    assert_equal 'available', states['observe.screen']
    assert_equal 'unverified', states['menu.open']
    assert_equal 'available', states['settings.read']
    assert_equal 'unverified', states['input']
    assert_equal 'available', states['input.other_sources']
  end

  def test_capabilities_without_a_profile_say_why
    @machine.full_game
    _, result, = @machine.run_json('capabilities')
    entries = result[:data][:capabilities].to_h { [it[:id], it] }

    assert_equal 'unsupported', entries['menu.open'][:state]
    assert_includes entries['menu.open'][:reason], 'build 111'
    assert_equal 'unsupported', entries['observe.screen'][:state]
  end
end
