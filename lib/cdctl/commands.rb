# frozen_string_literal: true

require_relative 'cli'
require_relative 'error_codes'
require_relative 'version'
require_relative 'commands/capabilities'
require_relative 'commands/doctor'
require_relative 'commands/lease'
require_relative 'commands/observation'
require_relative 'commands/observe'
require_relative 'commands/planned'
require_relative 'commands/schema'
require_relative 'commands/screenshot'
require_relative 'commands/status'

module Cdctl
  module Commands
    PROGRAM = 'cdctl'
    DESCRIPTION = 'Observe and control Crimson Desert from the command line, with evidence'
    LONG_DESCRIPTION = "#{DESCRIPTION}.\n\n" \
                       'cdctl finds the Steam installation, the game process and its window, and reports what it ' \
                       'can prove, including what it could not verify. Every command answers with versioned JSON ' \
                       "under --json; start with cdctl capabilities --json.\n\n" \
                       'It works on any machine that runs the game. What a machine lacks is reported, never ' \
                       'assumed. This version only observes: it sends nothing to the game.'.freeze

    # Help lists the commands in this order within their sections.
    COMMANDS = [Capabilities, Doctor, Schema, Status, Observe, Screenshot, Observation, LeaseCommands].freeze

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
        entries: [['CDCTL_STEAM_ROOT', 'Use this Steam directory instead of searching.'],
                  ['CDCTL_STATE_HOME', 'Where captures and observations are stored.'],
                  ['CDCTL_CONFIG', 'The configuration file.'],
                  [Lease::TOKEN_VARIABLE, 'The lease token, kept off the command line.'],
                  ['CDCTL_COLOR', 'When to use color: auto, always or never.']]
      )
    end
    private_class_method :environment
  end
end
