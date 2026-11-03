# frozen_string_literal: true

require 'test_helper'

class VdfTest < Minitest::Test
  def parse(text) = Cdctl::Steam::Vdf.parse(text)

  def test_reads_nested_blocks_and_comments
    tree = parse(%(// a comment\n"a"\n{\n\t"b"\t\t"c"\n\t"d"\n\t{\n\t\t"e"\t\t"f"\n\t}\n}\n))

    assert_equal({ 'a' => { 'b' => 'c', 'd' => { 'e' => 'f' } } }, tree)
  end

  def test_unescapes_a_windows_library_path
    assert_equal({ 'path' => 'C:\\Program Files\\Steam' }, parse('"path" "C:\\\\Program Files\\\\Steam"'))
  end

  def test_dig_ignores_the_case_steam_changes_between_files
    tree = parse('"AppState" { "BuildID" "7" }')

    assert_equal '7', Cdctl::Steam::Vdf.dig(tree, 'appstate', 'buildid')
  end

  def test_rejects_broken_files
    ['"a" {', '"a"', '"a" "b', '} "a"'].each do |text|
      assert_raises(Cdctl::Steam::Vdf::ParseError, text) { parse(text) }
    end
  end
end

class SteamDiscoveryTest < Minitest::Test
  def setup
    @machine = Machine.new
  end

  def teardown = @machine.destroy

  def installation_of(machine = @machine)
    machine.run_json('status')[1][:data][:installation]
  end

  def test_finds_a_native_install
    @machine.install_game(@machine.steam_root, build: '26', language: 'brazilian')
    found = installation_of

    assert_equal 'found', found[:state]
    assert_equal '26', found[:build_id]
    assert_equal 'brazilian', found[:language]
    assert_equal '9.0-1', found[:proton_version]
  end

  def test_finds_a_flatpak_install
    root = @machine.steam_root('.var/app/com.valvesoftware.Steam/.local/share/Steam')
    @machine.install_game(root)

    assert_equal root, installation_of[:steam_root]
  end

  def test_finds_the_game_in_a_second_library_on_another_disk
    other = File.join(@machine.home, 'mnt/games/SteamLibrary')
    FileUtils.mkdir_p(File.join(other, 'steamapps'))
    @machine.steam_root(libraries: [other])
    @machine.install_game(other)
    found = installation_of

    assert_equal other, found[:library]
    assert_equal File.join(other, 'steamapps/common/Crimson Desert'), found[:install_dir]
  end

  def test_a_symlinked_default_location_is_one_root
    root = @machine.steam_root
    FileUtils.mkdir_p(File.join(@machine.home, '.steam'))
    File.symlink(root, File.join(@machine.home, '.steam/steam'))
    @machine.install_game(root)

    assert_equal 'found', installation_of[:state]
  end

  def test_an_explicit_root_replaces_the_search
    @machine.install_game(@machine.steam_root)
    other = File.join(@machine.home, 'elsewhere')
    FileUtils.mkdir_p(File.join(other, 'steamapps'))
    @machine.env['CDCTL_STEAM_ROOT'] = other

    assert_equal 'not_found', installation_of[:state]
  end

  def test_reports_the_places_it_searched_when_steam_is_missing
    found = installation_of

    assert_equal 'not_found', found[:state]
    assert_includes found[:searched], File.join(@machine.home, '.local/share/Steam')
  end

  def test_a_broken_library_file_still_finds_the_game_in_the_root
    root = @machine.steam_root
    @machine.install_game(root)
    File.write(File.join(root, 'steamapps/libraryfolders.vdf'), '"libraryfolders" {')

    assert_equal 'found', installation_of[:state]
  end

  def test_a_manifest_cannot_point_outside_its_library
    root = @machine.steam_root
    @machine.install_game(root)
    manifest = File.join(root, "steamapps/appmanifest_#{Machine::APP_ID}.acf")
    File.write(manifest, File.read(manifest).sub(/("installdir"\s+)"[^"]+"/, '\1"../../evil"'))
    found = installation_of

    assert_equal 'not_found', found[:state]
    assert_match(/invalid installdir/, found[:problems].join)
  end

  def test_two_installs_are_ambiguous_until_the_running_game_decides
    first = @machine.steam_root
    second = File.join(@machine.home, 'other-library')
    FileUtils.mkdir_p(File.join(second, 'steamapps'))
    @machine.write_library_folders(first, [first, second])
    @machine.install_game(first)
    @machine.install_game(second)

    assert_equal 'ambiguous', installation_of[:state]

    @machine.run_game(env: { 'STEAM_COMPAT_DATA_PATH' => File.join(second, "steamapps/compatdata/#{Machine::APP_ID}") })

    assert_equal second, installation_of[:library]
  end

  def test_the_fingerprint_follows_the_depots
    root = @machine.steam_root
    @machine.install_game(root, depot: '1')
    before = installation_of[:build_fingerprint]
    @machine.install_game(root, depot: '2')

    refute_equal before, installation_of[:build_fingerprint]
  end

  def test_reads_the_version_from_the_data_index
    @machine.install_game(@machine.steam_root, version: [2, 4, 5])
    version = installation_of[:version]

    assert_equal '2.04.05', version[:value]
    assert_equal 'inferred', version[:confidence]
  end

  def test_version_sources_that_disagree_answer_unknown
    root = @machine.install_game(@machine.steam_root, version: [2, 4, 5])
    log = File.join(root,
                    "steamapps/compatdata/#{Machine::APP_ID}/pfx/drive_c/users/steamuser/AppData/Local/Pearl Abyss/log")
    FileUtils.mkdir_p(log)
    File.write(File.join(log, 'Launcher_2026.log'), "(x) [I] [Success](0) [GameVersion: 2.04.04]]\n")
    version = installation_of[:version]

    assert_equal 'unknown', version[:status]
    assert_match(/disagree/, version[:reason])
  end

  def test_windows_paths_are_searched_on_windows
    candidates = Cdctl::Steam::Roots.candidates(platform: Cdctl::Platform::WINDOWS, home: 'C:/Users/x',
                                                env: { 'ProgramFiles(x86)' => 'C:/Program Files (x86)' })

    assert_equal ['C:/Program Files (x86)/Steam'], candidates
  end
end
