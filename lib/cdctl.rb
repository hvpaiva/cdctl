# frozen_string_literal: true

require_relative 'cdctl/version'
require_relative 'cdctl/cli'
require_relative 'cdctl/runtime'
require_relative 'cdctl/commands'

# Observe and control Crimson Desert from the command line, with evidence.
module Cdctl
  # Shared by exe/cdctl and the tests, so it returns the exit status instead of exiting. The
  # factory is called only once a command runs, so help works with a broken configuration file.
  def self.run(argv, context: CLI::Context.system, runtime_factory: Runtime.method(:build))
    CLI::Runner.new(Commands.registry(runtime_factory), context).run(argv)
  end
end
