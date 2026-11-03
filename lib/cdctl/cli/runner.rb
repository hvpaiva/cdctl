# frozen_string_literal: true

require_relative 'errors'
require_relative 'style'
require_relative 'globals'
require_relative 'parser'
require_relative 'validator'
require_relative 'help_renderer'
require_relative 'builtins'
require_relative '../invocation'

module Cdctl
  module CLI
    # Returns the exit status and never lets an exception escape as a backtrace. Once --json is on
    # the line, every failure reaches stdout as a result document, usage errors included, so a
    # caller parsing JSON never has to guess why it received nothing.
    class Runner
      SIGNAL_STATUS = 130
      EPIPE_STATUS = 0
      UNEXPECTED_STATUS = 1
      COLOR_VARIABLE = 'CDCTL_COLOR'
      DEBUG_VARIABLE = 'CDCTL_DEBUG'
      COLOR_FLAG = "--#{Globals::COLOR.long}".freeze
      COLOR_INLINE = "#{COLOR_FLAG}=".freeze
      HELP_FLAG = "--#{Globals::HELP.long}".freeze
      JSON_FLAG = "--#{Globals::JSON.long}".freeze
      REQUEST_ID_FLAG = "--#{Globals::REQUEST_ID.long}".freeze
      REQUEST_ID_INLINE = "#{REQUEST_ID_FLAG}=".freeze

      def initialize(registry, context)
        @registry = registry
        @context = context
        @words = []
      end

      # The Context drops output once a stream's reader is gone, so a broken pipe reaching here
      # comes from a handler writing past the Context; it ends the run quietly.
      def run(argv)
        execute(argv.dup)
      rescue Errno::EPIPE
        EPIPE_STATUS
      end

      private

      # Color and JSON are settled first, from flags typed anywhere on the line, so even an error
      # in the parse that follows is reported the way the user asked.
      def execute(argv)
        settle_flags(argv)
        dispatch(argv)
      rescue Errno::EPIPE
        raise
      rescue Cdctl::Error => e
        report(e)
        e.exit_status
      rescue SignalException => e
        report(Cdctl::Error.interrupted(e))
        SIGNAL_STATUS
      rescue StandardError => e
        report_unexpected(e)
        UNEXPECTED_STATUS
      end

      def settle_flags(argv)
        @flag_color = flag_color(argv)
        @long_help = long_help?(argv)
        @json = argv.take_while { it != '--' }.include?(JSON_FLAG)
        @request_id = flag_request_id(argv)
        colorize({})
      end

      # A failure can come before the parse reaches it, and the caller still correlates by this id.
      # One that is not valid is left out, since the failure may be about that very id.
      def flag_request_id(argv)
        words = argv.take_while { it != '--' }
        index = words.index(REQUEST_ID_FLAG)
        inline = words.find { it.start_with?(REQUEST_ID_INLINE) }&.delete_prefix(REQUEST_ID_INLINE)
        typed = index ? words[index + 1] : inline
        typed if Invocation::REQUEST_ID.match?(typed.to_s)
      end

      def dispatch(argv)
        values = {}
        command, path, rest = walk(argv, values)
        return run_raw(command, rest) if command.raw

        args = parse(@registry.globals + command.options, path, values) { it.permute!(rest) }
        opts = defaults(command, values)
        return show_help(command, path, opts) if opts[:help]
        return show_version(opts) if opts[:version]
        return missing_command(command, path) if command.group?

        Validator.new(command, path, @registry).call(args, opts)
        invoke(command, path, args, opts)
      end

      # Globals are parsed before every word, so they may appear before the command and between a
      # group and its subcommand.
      def walk(argv, values)
        command = @registry.root
        path = []
        while command.group?
          argv = parse(@registry.globals, path, values) { it.order!(argv) }
          word = argv.shift
          return [command, path, argv] if word.nil?

          command = command.find(word) or raise unknown_command(word, path)
          path << word
          @words = path.dup
        end
        [command, path, argv]
      end

      def unknown_command(word, path)
        UsageError.new(@registry.unknown_command(word, path), hint: @registry.run_hint(path))
      end

      # Color is re-resolved after every parse step, so a `--color` the parser has just read
      # applies to the error that may follow it.
      def parse(options, path, values)
        parser = Parser.new(options, values)
        yield parser
      rescue OptionParser::InvalidOption => e
        raise UsageError.new(@registry.unknown_option(e.args.first, options), hint: @registry.help_hint(path))
      rescue OptionParser::ParseError => e
        raise UsageError.new(e.message, hint: @registry.help_hint(path))
      ensure
        colorize(values)
      end

      def defaults(command, values)
        Parser.new(@registry.globals + command.options, values).defaults.freeze
      end

      # Taken as typed; the Validator reports an invalid value once the parse reaches it.
      def flag_color(argv)
        argv.take_while { it != '--' }.reverse_each do |word|
          return Globals::COLOR.implicit if word == COLOR_FLAG
          return word.delete_prefix(COLOR_INLINE) if word.start_with?(COLOR_INLINE)
        end
        nil
      end

      # `-h` and `--help` set the same value; only `--help` is looked for, since `-h` can sit in a
      # cluster.
      def long_help?(argv) = argv.take_while { it != '--' }.include?(HELP_FLAG)

      def colorize(values)
        @context = @context.with_color(values.fetch(:color) { @flag_color || fallback_color })
      end

      def fallback_color
        value = @context.env[COLOR_VARIABLE]
        Style::MODES.include?(value) ? value : Style::DEFAULT_MODE
      end

      def invoke(command, path, args, opts)
        status = command.handler.call(@context, args, opts)
        status.is_a?(Integer) ? status : 0
      rescue UsageError => e
        raise if e.hint

        raise UsageError.new(e.message, hint: @registry.help_hint(path))
      end

      def run_raw(command, rest)
        status = command.handler.call(@context, rest, {})
        status.is_a?(Integer) ? status : 0
      end

      def show_help(command, path, opts)
        if @json
          text = help(command, path, long: @long_help, style: Style.disabled)
          Builtins.answer_json(@context, opts, Builtins::HELP, { topic: path.join(' '), text: })
        else
          @context.print(help(command, path, long: @long_help, style: @context.style))
        end
        0
      end

      def missing_command(command, path)
        if @json
          report(UsageError.new("#{[@registry.program, *path].join(' ')} needs a command",
                                hint: @registry.help_hint(path)))
        else
          @context.warn(help(command, path, long: false, style: @context.err_style))
        end
        ErrorCodes.category('USAGE').exit_status
      end

      def help(command, path, long:, style:)
        renderer = HelpRenderer.new(@registry, style, width: @context.columns)
        command.equal?(@registry.root) ? renderer.root(long:) : renderer.command(command, path, long:)
      end

      def show_version(opts)
        program = @registry.program
        version = @registry.version
        if @json
          Builtins.answer_json(@context, opts, Builtins::VERSION, Builtins.version_data(program, version))
        else
          @context.puts(Builtins.version_line(program, version))
        end
        0
      end

      def report(error)
        return report_json(error) if @json

        report_text(error)
      end

      def report_json(error)
        invocation = Invocation.new(command: @words.join(' '), request_id: Invocation.request_id(@request_id))
        @context.puts(invocation.failure(error).to_json_document(pretty: @context.tty))
      end

      # A message can quote a path, a window title or a typed word, so nothing reaches stderr raw.
      # Only a usage error keeps its line feeds, for its "Did you mean this?" list.
      def report_text(error)
        prefix = @context.paint_err(:error, 'error:')
        @context.warn("#{prefix} #{Style.plain(error.message, layout: error.is_a?(UsageError))}")
        @context.warn(Style.plain(error.hint)) if error.hint
        error.next_steps.each { @context.warn("next: #{Style.plain(it)}") }
      end

      def report_unexpected(error)
        report(Cdctl::Error.new(error.message, code: 'INTERNAL_ERROR'))
        return if @context.env[DEBUG_VARIABLE].to_s.empty?

        @context.warn(error.class.name, *Array(error.backtrace).map { "    #{it}" })
      end
    end
  end
end
