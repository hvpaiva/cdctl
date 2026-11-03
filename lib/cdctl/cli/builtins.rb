# frozen_string_literal: true

require_relative '../invocation'

module Cdctl
  module CLI
    module Builtins
      VERSION = 'version'
      HELP = 'help'

      def self.all(program:, version:, resolve:)
        [help(program:, resolve:), version(program:, version:)]
      end

      def self.version_line(program, version)
        "#{program} #{version} (ruby #{RUBY_VERSION}) [#{Gem::Platform.local}]"
      end

      def self.version_data(program, version)
        { program:, version:, ruby: RUBY_VERSION, platform: Gem::Platform.local.to_s }
      end

      # The answer in the same envelope as every other command, so a caller under --json never has
      # to tell apart which commands print a document.
      def self.answer_json(context, opts, command, data)
        invocation = Invocation.new(command:, request_id: Invocation.request_id(opts[:request_id]))
        context.puts(invocation.success(data:).to_json_document(pretty: context.tty))
      end

      def self.help(program:, resolve:)
        Command.new(
          name: HELP, summary: 'Help about any command', section: 'Other Commands',
          description: "Help provides help for any command in the application.\n" \
                       "Type #{program} help [path to command] for full details.",
          examples: [Example.new(comment: 'Show the help of a nested command', command: 'help observation check')],
          positionals: [Positional.new(name: 'COMMAND', required: false, variadic: true,
                                       description: 'The command to describe, such as observation check.')],
          handler: HelpCommand.new(resolve)
        )
      end

      def self.version(program:, version:)
        Command.new(
          name: VERSION, summary: "Print the version of #{program}", section: 'Other Commands',
          description: "Print the version of #{program}, the Ruby it runs on and the platform.",
          examples: [Example.new(comment: 'Print the version', command: 'version')],
          handler: lambda do |context, _args, opts|
            next answer_json(context, opts, VERSION, version_data(program, version)) if opts[:json]

            context.puts(version_line(program, version))
          end
        )
      end

      class HelpCommand
        def initialize(resolve)
          @resolve = resolve
        end

        def call(context, args, opts)
          registry = @resolve.call
          command, path = registry.resolve(args)
          style = opts[:json] ? Style.disabled : context.style
          renderer = HelpRenderer.new(registry, style, width: context.columns)
          text = command.equal?(registry.root) ? renderer.root : renderer.command(command, path)
          return Builtins.answer_json(context, opts, HELP, { topic: path.join(' '), text: }) if opts[:json]

          context.print(text)
        end
      end
    end
  end
end
