# frozen_string_literal: true

require 'did_you_mean'
require_relative 'errors'

module Cdctl
  module CLI
    SECTION_ORDER = ['Discovery Commands', 'Observation Commands', 'Control Commands', 'Other Commands'].freeze

    # `long` has no dashes, and a nil `argument` makes a boolean flag. An `optional` option takes
    # its value only attached (--long=VALUE) and stores `implicit` when it is omitted.
    Option = Data.define(:long, :short, :argument, :enum, :default, :description, :summary,
                         :required, :optional, :implicit) do
      def initialize(long:, description:, summary: nil, short: nil, argument: nil, enum: nil, default: nil,
                     required: false, optional: false, implicit: nil)
        super
      end

      def key = long.tr('-', '_').to_sym

      def flag? = argument.nil?

      def switches = [short && "-#{short}", "--#{long}"].compact

      def switch_spec
        long_spec = if flag? then "--#{long}"
                    elsif optional then "--#{long}[=#{argument}]"
                    else "--#{long} #{argument}"
                    end
        [short && "-#{short}", long_spec].compact
      end

      def label
        text = switches.join(', ')
        return text if flag?

        optional ? "#{text}[=<#{argument}>]" : "#{text} <#{argument}>"
      end

      def short_description = summary || description.delete_suffix('.')

      def notes
        [("[default: #{default}]" unless default.nil? || default == false),
         ("[possible values: #{enum.join(', ')}]" if enum)].compact
      end

      def accept(raw)
        return true if flag?
        return implicit if optional && raw.nil?

        raw
      end
    end

    Positional = Data.define(:name, :description, :required, :variadic, :enum) do
      def initialize(name:, description: nil, required: true, variadic: false, enum: nil)
        super
      end

      def usage
        token = required ? "<#{name}>" : "[#{name}]"
        variadic ? "#{token}..." : token
      end

      def short_description = description&.delete_suffix('.')

      def notes = enum ? ["[possible values: #{enum.join(', ')}]"] : []
    end

    # `command` omits the program name; help prepends it.
    Example = Data.define(:comment, :command)

    # A titled list of terms and what each means. `intro` is a paragraph printed above the terms.
    Glossary = Data.define(:title, :intro, :entries) do
      def initialize(title:, entries:, intro: nil) = super
    end

    # `handler` responds to call(context, args, opts) and may return an exit status. A `raw`
    # command receives argv untouched, with no option parsing.
    Command = Data.define(:name, :aliases, :summary, :description, :section, :examples, :positionals, :options,
                          :subcommands, :hidden, :raw, :handler, :usage, :glossaries) do
      def initialize(name:, summary:, description: nil, aliases: [], section: 'Available Commands', examples: [],
                     positionals: [], options: [], subcommands: [], hidden: false, raw: false, handler: nil,
                     usage: nil, glossaries: [])
        super(name:, summary:, description: description || summary, aliases:, section:, examples:,
              positionals:, options:, subcommands:, hidden:, raw:, handler:, usage:, glossaries:)
      end

      def group? = !subcommands.empty?

      def names = [name, *aliases]

      def find(word) = subcommands.find { it.names.include?(word) }

      def visible_subcommands = subcommands.reject(&:hidden)

      def sections
        visible_subcommands.group_by(&:section).sort_by.with_index do |(name, _), seen|
          [SECTION_ORDER.index(name) || SECTION_ORDER.size, seen]
        end
      end

      def positional_at(index) = positionals[index] || (positionals.last if positionals.last&.variadic)

      def min_args = positionals.count(&:required)

      def max_args = positionals.last&.variadic ? nil : positionals.size

      def usage_args
        return '<COMMAND>' if group?

        usage || positionals.map(&:usage).join(' ')
      end
    end

    # The single source of truth for help and dispatch.
    class Registry
      attr_reader :program, :version, :description, :globals, :root

      def initialize(program:, version:, description:, globals:, commands:, long_description: nil, glossaries: [])
        @program = program
        @version = version
        @description = description
        @globals = globals
        extra = Builtins.all(program:, version:, resolve: -> { self })
        @root = Command.new(name: program, summary: description, description: long_description, glossaries:,
                            subcommands: commands + extra)
      end

      def resolve(words)
        words.reduce([root, []]) do |(command, path), word|
          nxt = command.find(word)
          raise UsageError.new(unknown_command(word, path), hint: run_hint(path)) unless nxt

          [nxt, [*path, word]]
        end
      end

      def unknown_command(word, path)
        message = "unknown command #{word.inspect} for #{[program, *path].join(' ').inspect}"
        with_guesses(message, word, resolve(path).first.visible_subcommands.flat_map(&:names))
      end

      # OptionParser attaches "Did you mean?" only on its abbreviation-completing path, which
      # require_exact disables, so suggestions for long switches come from the registry.
      def unknown_option(word, options)
        name = word.sub(/=.*/, '')
        message = "unknown flag: #{name}"
        return message unless name.start_with?('--')

        with_guesses(message, name, options.map { "--#{it.long}" })
      end

      def help_hint(path) = "See '#{[program, *path, '--help'].join(' ')}' for usage."

      def run_hint(path) = "Run '#{[program, *path, '--help'].join(' ')}' for usage."

      private

      def with_guesses(message, word, dictionary)
        guesses = Suggest.similar(word, dictionary)
        return message if guesses.empty?

        "#{message}\n\nDid you mean this?\n#{guesses.map { "\t#{it}" }.join("\n")}\n\n"
      end
    end

    module Suggest
      DISTANCE = 2

      def self.similar(word, dictionary)
        dictionary.select do |candidate|
          DidYouMean::Levenshtein.distance(word, candidate) <= DISTANCE ||
            candidate.start_with?(word) || word.start_with?(candidate)
        end
      end
    end
  end
end
