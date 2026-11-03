# frozen_string_literal: true

require 'strscan'

module Cdctl
  module Steam
    # Valve's text KeyValues format, which Steam's library and manifest files use.
    module Vdf
      class ParseError < StandardError; end

      MAX_DEPTH = 64
      ESCAPES = { 'n' => "\n", 't' => "\t", '\\' => '\\', '"' => '"' }.freeze

      module_function

      def parse(text)
        scanner = StringScanner.new(String.new(text, encoding: Encoding::UTF_8).scrub)
        block(scanner, 0, top: true)
      end

      # Steam writes the same key with different case across files and versions.
      def dig(tree, *keys)
        keys.reduce(tree) do |node, key|
          break nil unless node.is_a?(Hash)

          node.fetch(key) { node.find { |name, _| name.casecmp?(key) }&.last }
        end
      end

      # The format lets any key hold a block, so a value expected to be text has to be checked.
      def text(tree, *keys)
        value = dig(tree, *keys)
        value if value.is_a?(String)
      end

      def block(scanner, depth, top: false)
        raise ParseError, 'nesting is too deep' if depth > MAX_DEPTH

        pairs = {}
        loop do
          key = token(scanner)
          return closed(pairs, top) if key.nil?
          return pairs if key == :close && !top
          raise ParseError, "unexpected #{key.inspect} at offset #{scanner.pos}" if key.is_a?(Symbol)

          pairs[key] = value(scanner, depth)
        end
      end
      private_class_method :block

      def closed(pairs, top)
        raise ParseError, 'missing closing brace' unless top

        pairs
      end
      private_class_method :closed

      def value(scanner, depth)
        item = token(scanner)
        return block(scanner, depth + 1) if item == :open
        raise ParseError, "a key has no value at offset #{scanner.pos}" if item.nil? || item.is_a?(Symbol)

        item
      end
      private_class_method :value

      def token(scanner)
        skip_blanks(scanner)
        return nil if scanner.eos?
        return :open if scanner.skip('{')
        return :close if scanner.skip('}')
        return quoted(scanner) if scanner.skip('"')

        scanner.scan(/[^\s{}"]+/) or raise ParseError, "unexpected text at offset #{scanner.pos}"
      end
      private_class_method :token

      # A conditional such as [$WIN32] may follow a value; no file cdctl reads depends on one.
      def skip_blanks(scanner)
        loop { break unless scanner.skip(%r{\s+|//[^\n]*|\[\$[^\]]*\]}) }
      end
      private_class_method :skip_blanks

      def quoted(scanner)
        body = scanner.scan(/(?:[^"\\]|\\.)*/m)
        raise ParseError, 'unterminated string' unless scanner.skip('"')

        body.gsub(/\\(.)/m) { ESCAPES.fetch(it[1], it[1]) }
      end
      private_class_method :quoted
    end
  end
end
