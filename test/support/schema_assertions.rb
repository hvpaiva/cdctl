# frozen_string_literal: true

require 'json_schemer'

module SchemaAssertions
  def assert_valid(name, document)
    errors = JSONSchemer.schema(Cdctl::Schemas.document(name)).validate(JSON.parse(JSON.generate(document))).to_a
    messages = errors.map { "#{it['data_pointer']}: #{it['error']}" }

    assert_empty messages, "#{name} result breaks its schema"
  end
end
