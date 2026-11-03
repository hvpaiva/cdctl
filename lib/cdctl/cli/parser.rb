# frozen_string_literal: true

require 'optparse'

module Cdctl
  module CLI
    class Parser
      def initialize(options, values)
        @options = options
        @values = values
      end

      def order!(argv) = parser.order!(argv)

      def permute!(argv) = parser.permute!(argv)

      def defaults
        @options.each { |opt| @values[opt.key] = opt.default unless @values.key?(opt.key) }
        @values
      end

      private

      def parser
        @parser ||= OptionParser.new do |o|
          o.require_exact = true
          drop_officious_completion(o)
          @options.each do |opt|
            o.on(*opt.switch_spec) { |raw| @values[opt.key] = opt.accept(raw) }
          end
        end
      end

      # OptionParser registers `--*-completion-bash=WORD` and `--*-completion-zsh` on every parser;
      # both print to $stdout and call `exit` mid-parse, which bypasses the Context and the
      # exit-code contract. `--help` and `--version` are shadowed by the registry's own switches.
      def drop_officious_completion(parser)
        parser.base.long.delete_if { |name, _| name.start_with?('*-') }
      end
    end
  end
end
