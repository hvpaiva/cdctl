# frozen_string_literal: true

require_relative 'vdf'
require_relative 'roots'
require_relative 'installation'

module Cdctl
  module Steam
    # Reads Steam's own files and nothing else. A file that cannot be parsed becomes a problem in
    # the report, not a guess: the other libraries may still hold the game.
    class Locator
      Report = Data.define(:searched, :roots, :installations, :problems)

      def initialize(candidates:, app_id:)
        @candidates = candidates
        @app_id = app_id
      end

      def locate
        @problems = []
        roots = Roots.existing(@candidates)
        found = roots.flat_map { |root| libraries(root).filter_map { read(root, it) } }
        Report.new(searched: @candidates, roots:, installations: found.uniq { File.realpath(it.manifest_path) },
                   problems: @problems)
      end

      private

      def libraries(root)
        path = File.join(root, 'steamapps', 'libraryfolders.vdf')
        return [root] unless File.file?(path)

        folders = Vdf.dig(Vdf.parse(File.binread(path)), 'libraryfolders')
        return [root] if folders.nil?

        unless folders.is_a?(Hash)
          problem(path, 'its libraryfolders entry is not a block')
          return [root]
        end

        [root, *folders.values.filter_map { library_path(it) }]
      rescue Vdf::ParseError, SystemCallError => e
        @problems << "#{path}: #{e.message}"
        [root]
      end

      # Steam once wrote a library as a bare string; current versions write a block with "path".
      def library_path(entry)
        entry.is_a?(Hash) ? Vdf.text(entry, 'path') : entry
      end

      def read(root, library)
        path = File.join(library, 'steamapps', "appmanifest_#{@app_id}.acf")
        return nil unless File.file?(path)

        state = Vdf.dig(Vdf.parse(File.binread(path)), 'AppState')
        return problem(path, 'it has no AppState block') unless state.is_a?(Hash)

        build(root, library, path, state)
      rescue Vdf::ParseError, SystemCallError => e
        problem(path, e.message)
      end

      def build(root, library, path, state)
        directory = Vdf.text(state, 'installdir').to_s
        return problem(path, "invalid installdir #{directory.inspect}") unless plain_name?(directory)

        compat = File.join(library, 'steamapps', 'compatdata', @app_id.to_s)
        compat = nil unless File.directory?(compat)
        Installation.new(
          app_id: @app_id, name: Vdf.text(state, 'name'), root:, library:, manifest_path: path,
          install_path: File.join(library, 'steamapps', 'common', directory), build_id: Vdf.text(state, 'buildid'),
          state_flags: Vdf.text(state, 'StateFlags').to_i, language: language(state), depots: depots(state),
          compat_data_path: compat, proton_version: compat && proton_version(compat)
        )
      end

      # The manifest decides a path under the library, so it must not be able to leave it.
      def plain_name?(name)
        !name.empty? && name != '.' && name != '..' && !name.match?(%r{[/\\]})
      end

      def language(state)
        Vdf.text(state, 'UserConfig', 'language') || Vdf.text(state, 'MountedConfig', 'language')
      end

      def depots(state)
        block = Vdf.dig(state, 'InstalledDepots')
        return {} unless block.is_a?(Hash)

        block.select { |_, depot| depot.is_a?(Hash) }.transform_values { Vdf.text(it, 'manifest') }
      end

      def proton_version(compat)
        path = File.join(compat, 'version')
        File.file?(path) ? File.foreach(path, chomp: true).first : nil
      rescue SystemCallError
        nil
      end

      def problem(path, message)
        @problems << "#{path}: #{message}"
        nil
      end
    end
  end
end
