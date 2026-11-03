# frozen_string_literal: true

require_relative 'cli'
require_relative 'error_codes'
require_relative 'version'
require_relative 'commands/planned'
require_relative 'commands/schema'

module Cdctl
  module Commands
    PROGRAM = 'cdctl'
    DESCRIPTION = 'Observe and control Crimson Desert from the command line, with evidence'
    LONG_DESCRIPTION = "#{DESCRIPTION}.\n\n" \
                       'Every command answers with versioned JSON under --json.'.freeze

    # Help lists the commands in this order within their sections.
    COMMANDS = [Schema].freeze

    def self.registry(factory)
      CLI::Registry.new(
        program: PROGRAM, version: VERSION, description: DESCRIPTION, long_description: LONG_DESCRIPTION,
        globals: CLI::Globals::ALL, glossaries: [exit_statuses, environment],
        commands: COMMANDS.map { it.command(factory) } + Planned.commands
      )
    end

    def self.exit_statuses
      CLI::Glossary.new(title: 'Exit Status', entries: ErrorCodes.exit_statuses.map do |code, meaning|
        [code.to_s, meaning]
      end)
    end
    private_class_method :exit_statuses

    def self.environment
      CLI::Glossary.new(
        title: 'Environment',
        entries: [['CDCTL_STATE_HOME', 'Where captures and observations are stored.'],
                  ['CDCTL_CONFIG', 'The configuration file.'],
                  ['CDCTL_COLOR', 'When to use color: auto, always or never.']]
      )
    end
    private_class_method :environment
  end
end
