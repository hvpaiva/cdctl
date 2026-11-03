# frozen_string_literal: true

require 'etc'
require 'time'
require_relative '../game'

module Cdctl
  module Game
    # Only these variables are ever read from another process, and none of them leaves cdctl
    # except DISPLAY: the rest of an environment can hold credentials.
    ENVIRONMENT_KEYS = %w[DISPLAY WAYLAND_DISPLAY XAUTHORITY STEAM_COMPAT_DATA_PATH STEAM_COMPAT_APP_ID
                          SteamAppId SteamGameId].freeze
    NESTED_COMPOSITORS = %w[gamescope gamescope-wl gamescopereaper].freeze

    RunningProcess = Data.define(:pid, :start_ticks, :boot_id, :started_at, :state, :comm, :environment,
                                 :ancestors, :evidence) do
      def nested? = ancestors.any? { NESTED_COMPOSITORS.include?(it) }

      def display = environment['DISPLAY']

      def compat_data_path = environment['STEAM_COMPAT_DATA_PATH']

      # A PID is reused and a boot resets start times, so only the three together name a process.
      def identity = "#{boot_id.to_s[0, 8]}-#{pid}-#{start_ticks}"

      def to_h
        { pid:, start_ticks:, started_at: started_at&.iso8601, comm:, display:, nested_compositor: nested?, evidence: }
      end
    end

    # Reads /proc. A process name alone once reported a running game as closed, so a match needs
    # the executable in argv[0], and no wrapper process has that: Proton and steam.exe carry the
    # game's path as a later argument.
    class ProcessScanner
      Scan = Data.define(:processes, :launching, :problem)

      EXECUTABLE_PATTERN = %r{(?:\A|[\\/])#{Regexp.escape(EXECUTABLE)}(?:\s|\z)}i
      MAX_ANCESTORS = 32

      def initialize(proc_root: '/proc', app_id: APP_ID, clock_ticks: Etc.sysconf(Etc::SC_CLK_TCK))
        @root = proc_root
        @app_id = app_id.to_s
        @clock_ticks = clock_ticks
      end

      def scan
        @boot_id = read(File.join(@root, 'sys', 'kernel', 'random', 'boot_id'))&.strip
        @boot_time = read(File.join(@root, 'stat'))&.[](/^btime (\d+)/, 1)&.to_i
        processes = []
        launching = false
        pids.each do |pid|
          argv = argv(pid)
          next if argv.nil?

          launching ||= launch_wrapper?(argv)
          found = examine(pid, argv)
          processes << found if found
        end
        Scan.new(processes:, launching:, problem: nil)
      rescue SystemCallError => e
        # Reporting no process here would claim the game is closed.
        Scan.new(processes: [], launching: false, problem: "cannot list processes: #{e.message.sub(/ @ .*\z/m, '')}")
      end

      private

      def pids = Dir.children(@root).grep(/\A\d+\z/)

      def argv(pid)
        read(File.join(@root, pid, 'cmdline'))&.split("\0")
      end

      # Steam's reaper names the app it launches, before the game has a process of its own.
      def launch_wrapper?(argv)
        argv[1] == 'SteamLaunch' && argv.include?("AppId=#{@app_id}")
      end

      def examine(pid, argv)
        return nil unless EXECUTABLE_PATTERN.match?(argv.first.to_s)

        stat = stat(pid)
        return nil if stat.nil? || stat[:state] == 'Z'

        environment = environment(pid)
        return nil if other_app?(environment)

        comm = read(File.join(@root, pid, 'comm')).to_s.strip
        build(pid, stat, comm, environment)
      end

      def build(pid, stat, comm, environment)
        RunningProcess.new(
          pid: pid.to_i, start_ticks: stat[:start_ticks], boot_id: @boot_id, started_at: started_at(stat), comm:,
          state: stat[:state], environment:, ancestors: ancestors(stat[:parent]), evidence: evidence(comm, environment)
        )
      end

      def other_app?(environment)
        ids = environment.values_at('SteamAppId', 'STEAM_COMPAT_APP_ID', 'SteamGameId').compact
        !ids.empty? && !ids.include?(@app_id)
      end

      def evidence(comm, environment)
        marks = ['executable_in_argv0']
        marks << 'comm_prefix' if comm.start_with?(COMM_PREFIX)
        marks << 'steam_app_environment' if environment.values_at('SteamAppId', 'STEAM_COMPAT_APP_ID').include?(@app_id)
        marks
      end

      def stat(pid)
        text = read(File.join(@root, pid.to_s, 'stat'))
        return nil unless text

        # comm can hold spaces and parentheses, so fields count from the last closing parenthesis.
        fields = text.rpartition(') ').last.split
        { state: fields[0], parent: fields[1], start_ticks: fields[19].to_i }
      end

      def ancestors(parent)
        names = []
        while parent.to_i > 1 && names.size < MAX_ANCESTORS
          names << read(File.join(@root, parent.to_s, 'comm')).to_s.strip
          parent = stat(parent)&.fetch(:parent)
        end
        names
      end

      def environment(pid)
        text = read(File.join(@root, pid, 'environ')) or return {}

        text.split("\0").each_with_object({}) do |entry, wanted|
          name, value = entry.split('=', 2)
          wanted[name] = value if ENVIRONMENT_KEYS.include?(name)
        end
      end

      def started_at(stat)
        return nil unless @boot_time && @clock_ticks

        Time.at(@boot_time + (stat[:start_ticks].to_f / @clock_ticks))
      end

      # A process can exit between listing it and reading it, and another user's is unreadable.
      def read(path)
        File.binread(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
