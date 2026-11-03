# frozen_string_literal: true

require 'time'
require_relative 'base'
require_relative '../observation_store'
require_relative '../observer'

module Cdctl
  module Commands
    class ObservationCheck < Base
      NAME = 'observation check'

      def self.command(factory)
        CLI::Command.new(
          name: 'check', summary: 'Say whether an observation still describes the game',
          description: 'Compare a stored observation with the game now. Different geometry, a different stored ' \
                       'resolution or a different HUD scale answers RESOLUTION_CHANGED and a different process or ' \
                       'window answers TARGET_CHANGED, so a coordinate from an old capture is never used by ' \
                       "accident.\n\n" \
                       'What could not be compared is listed under not_verified, and when the game cannot be read ' \
                       'at all the answer says why instead of guessing.',
          positionals: [CLI::Positional.new(name: 'ID', description: 'The id cdctl observe returned.')],
          options: [CLI::Option.new(long: 'max-age', argument: 'SECONDS',
                                    description: 'Also refuse an observation older than this.')],
          examples: [CLI::Example.new(comment: 'Check before using a coordinate',
                                      command: 'observation check obs-0123456789abcdef --max-age 30 --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, args, opts)
        saved = ObservationStore.new(runtime.paths.observations_dir).load(args.first)
        report = { observation_id: saved[:id], observed_at: saved[:observed_at], screenshot: saved[:screenshot],
                   age_seconds: (Time.now - Time.iso8601(saved[:observed_at])).round(3) }
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          differences = compare(saved, snapshot)
          judge(invocation, report.merge(differences:, valid: differences.empty?), snapshot, opts)
        end
      end

      def compare(saved, snapshot)
        current = snapshot.fingerprint
        return ObservationStore.differences(saved[:state], current) if current
        return [{ field: 'pid', was: saved.dig(:state, :pid), now: snapshot.process&.pid }] if gone?(saved, snapshot)

        # The observed process is still there, or cannot be told apart, and the look at it failed.
        # Saying it changed would be a guess, so the refusal explains what could not be read.
        snapshot.require_window!
        []
      end

      def gone?(saved, snapshot)
        scan = snapshot.scan
        return false if scan.nil? || scan.problem || scan.processes.size > 1

        found = snapshot.process
        found.nil? || [found.pid, found.start_ticks] != saved[:state].values_at(:pid, :start_ticks)
      end

      def judge(invocation, report, snapshot, opts)
        unless report[:valid]
          code = ObservationStore.error_code(report[:differences].map { it.merge(field: it[:field].to_sym) })
          raise Error.new('the game no longer matches this observation', code:, data: report, target: snapshot.target,
                                                                         next_steps: ['Run cdctl observe again.'])
        end
        too_old(report, snapshot, opts)
        invocation.success(data: report, target: snapshot.target, not_verified: snapshot.not_verified)
      end

      def too_old(report, snapshot, opts)
        limit = opts[:max_age] && Float(opts[:max_age], exception: false)
        raise CLI::UsageError, "invalid --max-age #{opts[:max_age].inspect}" if opts[:max_age] && limit.nil?
        return unless limit && report[:age_seconds] > limit

        raise Error.new("the observation is #{report[:age_seconds]} seconds old, over the #{limit} allowed",
                        code: 'OBSERVATION_STALE', data: report, target: snapshot.target,
                        next_steps: ['Run cdctl observe again.'])
      end

      def render(context, result)
        rows(context, [['Observation', result.data[:observation_id]], ['Valid', result.data[:valid].to_s],
                       ['Age', "#{result.data[:age_seconds]} s"]])
      end
    end

    module Observation
      def self.command(factory)
        CLI::Command.new(name: 'observation', section: 'Observation Commands',
                         summary: 'Work with stored observations',
                         subcommands: [ObservationCheck.command(factory)])
      end
    end
  end
end
