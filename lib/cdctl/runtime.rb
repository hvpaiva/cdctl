# frozen_string_literal: true

require_relative 'paths'
require_relative 'platform'
require_relative 'settings'
require_relative 'shell'
require_relative 'x11/connection'

module Cdctl
  # What a command needs from the outside world. Tests build one with fakes for /proc, the X server
  # and external programs, so no test can reach a real game on the machine running it.
  class Runtime
    attr_reader :env, :paths, :settings, :platform, :proc_root, :shell, :x11_opener

    def self.build(context, _opts)
      platform = Platform.current
      paths = Paths.new(context.env, platform:)
      new(env: context.env, paths:, settings: Settings.load(paths), platform:, proc_root: '/proc',
          shell: Shell.new(session_environment(context.env, paths)),
          x11_opener: X11::Connection.method(:open))
    end

    # An agent started from a service or a remote shell may lack the variables that locate the
    # desktop session; the session's own runtime directory is the one safe default.
    def self.session_environment(env, paths)
      return {} unless env['XDG_RUNTIME_DIR'].to_s.empty? && paths.runtime_dir

      { 'XDG_RUNTIME_DIR' => paths.runtime_dir }
    end
    private_class_method :session_environment

    def initialize(env:, paths:, settings:, platform:, proc_root:, shell:, x11_opener:)
      @env = env
      @paths = paths
      @settings = settings
      @platform = platform
      @proc_root = proc_root
      @shell = shell
      @x11_opener = x11_opener
    end

    def linux? = platform == Platform::LINUX

    # Leaves the environment out so a debugging print never dumps every variable of the process.
    def inspect = "#<#{self.class.name} platform=#{platform.inspect}>"
  end
end
