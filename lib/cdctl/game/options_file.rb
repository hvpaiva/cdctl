# frozen_string_literal: true

require 'time'
require_relative '../fact'
require_relative '../game'
require_relative '../platform'

module Cdctl
  module Game
    # The game writes this file when settings are applied, and not when it starts, so a file older
    # than the process is the one the process read. It is read here, never written. A field the
    # game omits is reported as omitted: the same absence can mean a default or something else, and
    # only a validated profile may say which.
    class OptionsFile
      class ParseError < StandardError; end

      Entry = Data.define(:path, :attributes)

      TAG = %r{<(/?)([A-Za-z_][\w:.-]*)((?:\s+[\w:.-]+="[^"]*")*)\s*(/?)>}
      ATTRIBUTE = /([\w:.-]+)="([^"]*)"/
      MAX_BYTES = 4 * 1024 * 1024
      SOURCE = 'option_file'
      VALUE_ATTRIBUTES = %w[_value _select].freeze

      attr_reader :path, :modified_at

      def self.location(installation, platform:, env:)
        base = base_directory(installation, platform, env)
        base && File.join(base, DATA_DIRECTORY, 'CD', 'save', OPTIONS_FILE)
      end

      def self.base_directory(installation, platform, env)
        return env['LOCALAPPDATA'] if platform == Platform::WINDOWS

        prefix = installation&.prefix_path
        prefix && File.join(prefix, 'drive_c', 'users', 'steamuser', 'AppData', 'Local')
      end
      private_class_method :base_directory

      def self.read(path)
        raise ParseError, "#{path} is larger than expected" if File.size(path) > MAX_BYTES

        new(path, File.binread(path), File.mtime(path))
      rescue SystemCallError => e
        raise ParseError, e.message.sub(/ @ \S+ - .*\z/m, '')
      end

      def initialize(path, text, modified_at)
        @path = path
        @modified_at = modified_at
        @entries = parse(String.new(text, encoding: Encoding::UTF_8).scrub)
      end

      def viewport_size
        fact('_viewportSize', '_value') do |value|
          numbers = value.split.map { Integer(it, 10, exception: false) }
          usable = numbers.size == 2 && numbers.all? { it&.positive? }
          raise ParseError, "unexpected value #{value.inspect}" unless usable

          { width: numbers.first, height: numbers.last }
        end
      end

      def upscale_resolution = fact('_upscaleResolution', '_select')

      def hud_scale = fact('_uiHudScale', '_value') { Integer(it, 10) }

      # The raw value. What it means in the menu belongs to a UI profile.
      def keyboard_mouse_preset = fact('_keyboardMousePresetOptionType', '_select')

      private

      # An element without its value is not an absent field: the file says something about it, in a
      # form this reader does not understand.
      def fact(name, attribute)
        matches = @entries.select { it.path.last == name }
        return Fact.unknown("#{name} appears #{matches.size} times") if matches.size > 1

        found = matches.first
        return Fact.known(nil, source: SOURCE, observed_at: modified_at.iso8601) unless found

        value = found.attributes.fetch(attribute) { raise ParseError, "it has no #{attribute}" }
        value = yield(value) if block_given?
        Fact.known(value, source: SOURCE, observed_at: modified_at.iso8601)
      rescue ArgumentError, ParseError => e
        Fact.unknown("#{name}: #{e.message}")
      end

      # The file is a small generated subset of XML, which needs no full parser and no gem. A path
      # is the chain of Name attributes, so two sections can hold the same element type.
      def parse(text)
        stack = []
        entries = []
        text.scan(TAG) do |closing, element, attributes, self_closing|
          if closing.empty?
            fields = attributes.scan(ATTRIBUTE).to_h
            path = [*stack, fields['Name'] || element]
            entries << Entry.new(path:, attributes: fields)
            stack.push(path.last) if self_closing.empty?
          elsif stack.pop.nil?
            raise ParseError, "unbalanced </#{element}>"
          end
        end
        raise ParseError, 'unbalanced elements' unless stack.empty?
        # Without this, an empty file would report every field as absent, which is a claim about
        # settings it does not hold.
        raise ParseError, 'it holds no settings' unless entries.any? { it.attributes.keys.intersect?(VALUE_ATTRIBUTES) }

        entries
      end
    end
  end
end
