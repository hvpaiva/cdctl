# frozen_string_literal: true

require_relative 'platform'

module Cdctl
  # Follows the XDG Base Directory Specification. Reads only the environment Hash it is given, so
  # tests never touch ENV.
  class Paths
    APP = 'cdctl'
    CONFIG_FILE = 'config.yaml'
    CONFIG_VARIABLE = 'CDCTL_CONFIG'
    STATE_VARIABLE = 'CDCTL_STATE_HOME'

    def initialize(env, platform: Platform.current)
      @env = env
      @platform = platform
    end

    def home = present(@env['HOME']) || present(@env['USERPROFILE']) || Dir.home

    def config_file
      present(@env[CONFIG_VARIABLE]) || File.join(config_home, APP, CONFIG_FILE)
    end

    def state_home
      present(@env[STATE_VARIABLE]) || File.join(state_base, APP)
    end

    def evidence_dir = File.join(state_home, 'evidence')

    def observations_dir = File.join(state_home, 'observations')

    def sessions_dir = File.join(state_home, 'sessions')

    def lease_dir = File.join(state_home, 'lease')

    def input_dir = File.join(state_home, 'input')

    def runtime_dir
      value = present(@env['XDG_RUNTIME_DIR'])
      return value if value && File.absolute_path?(value)
      return nil unless @platform == Platform::LINUX

      default = "/run/user/#{Process.uid}"
      default if File.directory?(default)
    end

    private

    def config_home
      return present(@env['APPDATA']) || File.join(home, 'AppData', 'Roaming') if windows?

      xdg('XDG_CONFIG_HOME', '.config')
    end

    def state_base
      return present(@env['LOCALAPPDATA']) || File.join(home, 'AppData', 'Local') if windows?

      xdg('XDG_STATE_HOME', File.join('.local', 'state'))
    end

    def windows? = @platform == Platform::WINDOWS

    # The specification says an unset or empty variable takes its default and a relative path is
    # invalid and ignored.
    def xdg(name, default)
      value = present(@env[name])
      return value if value && File.absolute_path?(value)

      File.join(home, default)
    end

    def present(value)
      value unless value.nil? || value.empty?
    end
  end
end
