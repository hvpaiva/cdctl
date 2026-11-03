# frozen_string_literal: true

module Cdctl
  # Facts about the game itself, true on every machine. Facts about a machine are discovered.
  module Game
    APP_ID = 3_321_460
    EXECUTABLE = 'CrimsonDesert.exe'
    # The kernel truncates a process name to 15 bytes, so the full name never appears in comm.
    COMM_PREFIX = 'CrimsonDesert'
    DATA_DIRECTORY = 'Pearl Abyss'
    OPTIONS_FILE = 'user_engine_option_save.xml'
    WINDOW_CLASS = "steam_app_#{APP_ID}".freeze
  end
end
