# frozen_string_literal: true

require_relative 'base'
require_relative '../doctor'
require_relative '../observer'

module Cdctl
  module Commands
    class Doctor < Base
      NAME = 'doctor'
      MARKS = { 'ok' => :success, 'warn' => :warning, 'fail' => :danger, 'info' => :muted, 'skip' => :muted }.freeze

      def self.command(factory)
        CLI::Command.new(
          name: NAME, section: 'Discovery Commands', summary: 'Check what cdctl needs on this machine',
          description: 'Check Steam, the installation, the state directory, X11, capture and the compositor, and ' \
                       "say how to fix what is missing. It sends nothing to the game.\n\n" \
                       'It exits with status 3 when a check fails. A closed game is not a failure.',
          examples: [CLI::Example.new(comment: 'Check this machine', command: 'doctor')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, _opts)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          checks = Cdctl::Doctor.new(snapshot:, connection: observer.connection, paths: runtime.paths).checks
          finish(invocation, snapshot, checks)
        end
      end

      def finish(invocation, snapshot, checks)
        data = { healthy: checks.none? { it[:status] == 'fail' }, checks: }
        return invocation.success(data:, target: snapshot.target) if data[:healthy]

        failed = checks.select { it[:status] == 'fail' }
        raise Error.new("#{failed.size} check(s) failed: #{failed.map { it[:id] }.join(', ')}",
                        code: 'PRECONDITION_FAILED', data:, target: snapshot.target,
                        next_steps: failed.filter_map { it[:remedy] })
      end

      def render(context, result)
        result.data[:checks].each { line(context, it) }
      end

      def report_failure(context, result)
        result.data&.dig(:checks)&.each { line(context, it) }
        super
      end

      def line(context, check)
        mark = context.paint(MARKS.fetch(check[:status]), check[:status].ljust(4))
        context.puts("#{mark}  #{check[:id].ljust(16)}  #{CLI::Style.plain(check[:detail])}")
        context.puts("      #{' ' * 16}  fix: #{CLI::Style.plain(check[:remedy])}") if check[:remedy]
      end
    end
  end
end
