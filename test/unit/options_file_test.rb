# frozen_string_literal: true

require 'test_helper'

class OptionsFileTest < Minitest::Test
  def file(text) = Cdctl::Game::OptionsFile.new('/x.xml', text, Time.at(0))

  def changes(earlier, later) = file(later).changes_since(file(earlier))

  def test_ids_the_game_regenerates_are_no_change
    from = '<A Name="r" IdBase="1"><B ItemID="5" _value="2"/></A>'
    to = '<A Name="r" IdBase="9"><B ItemID="7" _value="2"/></A>'

    assert_empty changes(from, to)
  end

  def test_an_attribute_that_is_not_a_value_is_still_a_change
    from = '<A Name="r" _selectPreset="Custom"><B Name="b" _value="2"/></A>'
    to = '<A Name="r" _selectPreset="High"><B Name="b" _value="2"/></A>'

    assert_equal [{ setting: 'r', was: { '_selectPreset' => 'Custom' }, now: { '_selectPreset' => 'High' } }],
                 changes(from, to)
  end

  def test_siblings_sharing_a_path_are_told_apart
    from = '<A Name="r"><B _value="1"/><B _value="2"/></A>'
    to = '<A Name="r"><B _value="9"/><B _value="2"/></A>'

    assert_equal [{ setting: 'r/B', was: { '_value' => '1' }, now: { '_value' => '9' } }], changes(from, to)

    to = '<A Name="r"><B _value="1"/><B _value="9"/></A>'

    assert_equal [{ setting: 'r/B#1', was: { '_value' => '2' }, now: { '_value' => '9' } }], changes(from, to)
  end

  def test_an_element_that_goes_away_is_a_change
    from = '<A Name="r"><B Name="b" _select="A"/><C Name="c" _value="1"/></A>'
    to = '<A Name="r"><C Name="c" _value="1"/></A>'

    assert_equal [{ setting: 'r/b', was: { '_select' => 'A' }, now: nil }], changes(from, to)
  end

  def test_a_stored_resolution_is_read
    assert_equal({ width: 2560, height: 1440 }, file(OptionFiles.sample(viewport: '2560 1440')).viewport_size.value)
  end

  def test_an_absent_field_is_a_known_absence_and_not_an_unknown
    fact = file(OptionFiles.sample).viewport_size

    assert_predicate fact, :known?
    assert_nil fact.value
  end

  def test_other_fields_keep_their_raw_values
    options = file(OptionFiles.sample(preset: 'A', hud_scale: 90, upscale: '67%'))

    assert_equal 'A', options.keyboard_mouse_preset.value
    assert_equal 90, options.hud_scale.value
    assert_equal '67%', options.upscale_resolution.value
  end

  def test_a_value_it_cannot_understand_is_unknown
    assert_equal 'unknown', file(OptionFiles.sample(viewport: 'wide')).viewport_size.status
  end

  def test_a_repeated_field_is_unknown_rather_than_a_guess
    repeated = OptionFiles.sample.sub('</EngineOptionVideo>',
                                      '<OptionInt Name="_uiHudScale" _value="50"/></EngineOptionVideo>')

    assert_equal 'unknown', file(repeated).hud_scale.status
  end

  def test_unbalanced_files_are_refused
    assert_raises(Cdctl::Game::OptionsFile::ParseError) { file('<a Name="x">') }
    assert_raises(Cdctl::Game::OptionsFile::ParseError) { file('</a>') }
  end

  def test_a_file_with_no_settings_is_refused
    ['', '<EngineOptionSave/>', '<EngineOptionSave _selectPreset="Custom"></EngineOptionSave>'].each do |text|
      error = assert_raises(Cdctl::Game::OptionsFile::ParseError, text) { file(text) }

      assert_match(/no settings/, error.message)
    end
  end

  def test_a_field_without_its_value_is_unknown_and_not_absent
    fact = file(OptionFiles.sample.sub('</EngineOptionVideo>',
                                       '<OptionInt2Vector Name="_viewportSize"/></EngineOptionVideo>')).viewport_size

    assert_equal 'unknown', fact.status
    assert_match(/no _value/, fact.reason)
  end

  def test_a_stored_resolution_needs_exactly_two_positive_numbers
    ['1920', '1920 1080 60', '0 1080', '-1 1080'].each do |viewport|
      assert_equal 'unknown', file(OptionFiles.sample(viewport:)).viewport_size.status, viewport
    end
  end

  def test_status_reads_the_file_without_touching_it
    machine = Machine.new
    machine.install_game(machine.steam_root, options: OptionFiles.sample)
    path = Cdctl::Game::OptionsFile.location(machine.runtime.then { Struct.new(:prefix_path).new(prefix(machine)) },
                                             platform: Cdctl::Platform::LINUX, env: {})
    before = File.stat(path).mtime
    settings = machine.run_json('status')[1][:data][:settings]

    assert_equal 'read', settings[:state]
    assert_equal before, File.stat(path).mtime
  ensure
    machine.destroy
  end

  def prefix(machine)
    File.join(machine.home, ".local/share/Steam/steamapps/compatdata/#{Machine::APP_ID}/pfx")
  end
end
