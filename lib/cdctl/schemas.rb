# frozen_string_literal: true

require 'json'
require_relative 'error'
require_relative 'error_codes'

module Cdctl
  # One self-contained JSON Schema per command, built from a shared envelope and the shape of that
  # command's data. A caller needs no other file and no network to validate a result.
  module Schemas
    DIRECTORY = File.expand_path('schemas', __dir__)
    NAMES = %w[help schema version].freeze
    PLANNED = %w[game.continue game.launch game.quit hud.radar input.click input.key lease.acquire lease.release
                 lease.renew lease.status menu.back menu.open settings.get settings.list settings.plan
                 settings.set].freeze

    module_function

    def document(name)
      return build(name) if NAMES.include?(name)

      if PLANNED.include?(name)
        raise Error.new("#{name} is planned but this version of cdctl does not implement it",
                        code: 'NOT_IMPLEMENTED')
      end

      raise Error.new("no schema named #{name.inspect}; known schemas: #{NAMES.join(', ')}", code: 'USAGE')
    end

    def build(name)
      envelope = load('envelope')
      envelope['title'] = "cdctl #{name} result"
      envelope['if'] = { 'properties' => { 'ok' => { 'const' => true } } }
      envelope['then'] = { 'properties' => { 'data' => load(name) } }
      envelope['$defs']['error']['properties']['code']['enum'] = ErrorCodes::CODES.keys
      envelope
    end
    private_class_method :build

    def load(name) = JSON.parse(File.read(File.join(DIRECTORY, "#{name}.json")))
    private_class_method :load
  end
end
