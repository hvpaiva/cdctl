# frozen_string_literal: true

require_relative 'base'
require_relative '../lease'

module Cdctl
  module Commands
    # The token leaves cdctl once, in the answer to acquire, and is stored only as a hash.
    module LeaseToken
      TOKEN_OPTION = CLI::Option.new(long: 'token', argument: 'TOKEN',
                                     description: "The token from cdctl lease acquire. #{Lease::TOKEN_VARIABLE} " \
                                                  'keeps it off the command line.')

      private

      def token_from(runtime, opts) = opts[:token] || runtime.env[Lease::TOKEN_VARIABLE]

      def required_token(runtime, opts)
        token_from(runtime, opts) or raise CLI::UsageError, "this needs --token or #{Lease::TOKEN_VARIABLE}"
      end

      def lease_rows(data)
        return [['State', [data[:state], data[:reason]].compact.join(': ')]] unless data[:state] == 'held'

        [%w[State held], ['Owner', data[:owner]], ['Purpose', data[:purpose]],
         ['Generation', data[:generation].to_s], ['Heartbeat', "#{data[:heartbeat_age_seconds]} s ago"],
         ['Orphan', orphan_text(data[:orphan])]]
      end

      def orphan_text(orphan)
        orphan[:suspected] ? "suspected: #{orphan[:reasons].join(', ')}" : 'no'
      end
    end

    class LeaseStatus < Base
      include LeaseToken

      NAME = 'lease status'

      def self.command(factory)
        CLI::Command.new(
          name: 'status', summary: 'Say who holds the input lease',
          description: 'Say who holds the input lease, why, and whether it looks orphaned. A lease never ends ' \
                       'because time passed: a suspected orphan stays held until someone takes it over explicitly.',
          examples: [CLI::Example.new(comment: 'Before asking for it', command: 'lease status --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, _opts)
        invocation.success(data: Lease.for(runtime).status)
      end

      def render(context, result) = rows(context, lease_rows(result.data))
    end

    class LeaseAcquire < Base
      include LeaseToken

      NAME = 'lease acquire'

      def self.command(factory)
        CLI::Command.new(
          name: 'acquire', summary: 'Take exclusive ownership of input',
          description: 'Take exclusive ownership of input, and answer with a token that every input command needs. ' \
                       "Nothing else ever prints the token.\n\n" \
                       'A lease coordinates programs. It cannot stop the person at the keyboard, and input that ' \
                       "sees them stops with USER_INTERFERENCE.\n\n" \
                       'While another owner holds it this answers LEASE_BUSY. --takeover ends a suspected orphan, ' \
                       'and also needs --force when nothing suggests the owner is gone. A takeover is logged, and ' \
                       'the old token stops working at once.',
          options: options,
          examples: [CLI::Example.new(comment: 'Ask for it',
                                      command: 'lease acquire --owner agent-a --purpose "check a preset" --json')],
          handler: new(factory)
        )
      end

      def self.options
        [CLI::Option.new(long: 'owner', argument: 'ID', required: true,
                         description: 'Who is asking, in your own words.'),
         CLI::Option.new(long: 'purpose', argument: 'TEXT', required: true, description: 'What it is for.'),
         CLI::Option.new(long: 'holder-pid', argument: 'PID',
                         description: 'A long-lived process of yours. Its end marks the lease as a suspected orphan.'),
         CLI::Option.new(long: 'takeover', description: 'End the current lease and take its place.'),
         CLI::Option.new(long: 'force', description: 'With --takeover, even when nothing suggests the owner is gone.'),
         CLI::Option.new(long: 'reason', argument: 'TEXT', description: 'Why a takeover is right. It goes in the log.')]
      end
      private_class_method :options

      private

      def perform(invocation, runtime, _args, opts)
        report, token = Lease.for(runtime).acquire(
          owner: opts[:owner], purpose: opts[:purpose], request_id: invocation.request_id, takeover: opts[:takeover],
          force: opts[:force], reason: opts[:reason], holder_pid: holder_pid(opts[:holder_pid])
        )
        invocation.success(data: report.merge(token:), changed: true,
                           actions: [{ type: 'lease_acquired', generation: report[:generation] }])
      end

      def holder_pid(text)
        return nil unless text

        pid = Integer(text, 10, exception: false)
        raise CLI::UsageError, "invalid --holder-pid #{text.inspect}" unless pid&.positive?

        pid
      end

      def render(context, result)
        rows(context, [['Token', result.data[:token]], *lease_rows(result.data)])
      end
    end

    class LeaseRenew < Base
      include LeaseToken

      NAME = 'lease renew'

      def self.command(factory)
        CLI::Command.new(
          name: 'renew', summary: 'Record that the owner is still there',
          description: 'Record a heartbeat. Skipping it never ends a lease; it only lets others see the owner has ' \
                       'gone quiet. A token that no longer holds the lease answers LEASE_LOST and changes nothing.',
          options: [TOKEN_OPTION],
          examples: [CLI::Example.new(comment: 'Between long steps', command: 'lease renew --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, opts)
        report = Lease.for(runtime).renew(required_token(runtime, opts), request_id: invocation.request_id)
        invocation.success(data: report, changed: true,
                           actions: [{ type: 'lease_renewed', generation: report[:generation] }])
      end

      def render(context, result) = rows(context, lease_rows(result.data))
    end

    class LeaseRelease < Base
      include LeaseToken

      NAME = 'lease release'

      def self.command(factory)
        CLI::Command.new(
          name: 'release', summary: 'Give up the input lease',
          description: 'Give up the input lease. Sending this twice is harmless. A token from before a takeover ' \
                       'answers LEASE_LOST and leaves the current lease alone.',
          options: [TOKEN_OPTION],
          examples: [CLI::Example.new(comment: 'When done', command: 'lease release --token TOKEN --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, opts)
        report, changed = Lease.for(runtime).release(required_token(runtime, opts), request_id: invocation.request_id)
        invocation.success(data: report, changed:,
                           actions: changed ? [{ type: 'lease_released', generation: report[:generation] }] : [])
      end

      def render(context, result) = rows(context, lease_rows(result.data))
    end

    module LeaseCommands
      def self.command(factory)
        CLI::Command.new(name: 'lease', section: 'Control Commands', summary: 'Coordinate input between programs',
                         subcommands: [LeaseStatus, LeaseAcquire, LeaseRenew, LeaseRelease].map { it.command(factory) })
      end
    end
  end
end
