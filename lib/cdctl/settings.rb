# frozen_string_literal: true

require 'yaml'
require_relative 'error'

module Cdctl
  # Nothing here is required: every value is discovered or has a default, so a machine with no
  # configuration file works the same as one with an empty file.
  class Settings
    KEYS = %w[steam_root ignored_overlay_layers evidence_keep].freeze
    # Overlay surfaces that never take input. Anything else on the overlay layer counts as a dialog.
    DEFAULT_IGNORED_LAYERS = ['*notification*', 'mako', 'dunst', 'swaync*', 'fnott', '*osd*', 'wob'].freeze
    DEFAULT_EVIDENCE_KEEP = 100

    attr_reader :steam_root, :ignored_overlay_layers, :evidence_keep

    def self.load(paths)
      path = paths.config_file
      return new unless File.file?(path)

      new(**parse(path))
    end

    def self.parse(path)
      values = YAML.safe_load_file(path) || {}
      invalid(path, 'the top level must be a mapping') unless values.is_a?(Hash)
      unknown = values.keys - KEYS
      invalid(path, "unknown key #{unknown.first.inspect}; known keys: #{KEYS.join(', ')}") unless unknown.empty?
      validate(path, values)
      # A key written with no value means the same as leaving it out.
      values.compact.transform_keys(&:to_sym)
    rescue Psych::Exception, SystemCallError => e
      invalid(path, e.message)
    end
    private_class_method :parse

    def self.validate(path, values)
      root = values['steam_root']
      invalid(path, '"steam_root" must be a string') unless root.nil? || root.is_a?(String)
      layers = values['ignored_overlay_layers']
      unless layers.nil? || (layers.is_a?(Array) && layers.all?(String))
        invalid(path, '"ignored_overlay_layers" must be a list of strings')
      end
      keep = values['evidence_keep']
      return if keep.nil? || (keep.is_a?(Integer) && keep.positive?)

      invalid(path, '"evidence_keep" must be a positive integer')
    end
    private_class_method :validate

    def self.invalid(path, problem)
      raise Error.new("#{path}: #{problem}", code: 'INVALID_CONFIG')
    end
    private_class_method :invalid

    def initialize(steam_root: nil, ignored_overlay_layers: [], evidence_keep: DEFAULT_EVIDENCE_KEEP)
      @steam_root = steam_root
      @ignored_overlay_layers = (DEFAULT_IGNORED_LAYERS + ignored_overlay_layers).uniq.freeze
      @evidence_keep = evidence_keep
    end
  end
end
