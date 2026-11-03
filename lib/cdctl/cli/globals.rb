# frozen_string_literal: true

require_relative 'registry'
require_relative 'style'

module Cdctl
  module CLI
    # The Runner reads help, version, color and json from the parsed values by these keys.
    module Globals
      JSON = Option.new(long: 'json', summary: 'Print only the versioned JSON result on stdout',
                        description: 'Print only the versioned JSON result on stdout. Progress and warnings go to ' \
                                     'stderr. See "cdctl schema".')
      REQUEST_ID = Option.new(long: 'request-id', argument: 'ID',
                              description: 'An id to echo in the result, to correlate it with your own log.')
      COLOR = Option.new(long: 'color', argument: 'WHEN', optional: true, implicit: 'always', enum: Style::MODES,
                         description: 'When to use color in the output; a bare --color means always.')
      HELP = Option.new(long: 'help', short: 'h', summary: "Print help (see more with '--help')",
                        description: "Print help (see a summary with '-h').")
      VERSION = Option.new(long: 'version', short: 'V', description: 'Print the version and exit.')

      ALL = [JSON, REQUEST_ID, COLOR, HELP, VERSION].freeze
    end
  end
end
