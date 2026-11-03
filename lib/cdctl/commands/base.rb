# frozen_string_literal: true

require_relative '../cli'
require_relative '../invocation'

module Cdctl
  module Commands
    # Runs one command under the result contract: a subclass returns a Result, or raises an Error
    # that becomes one. Text goes to stderr as `error:` lines only in human mode; with --json the
    # document on stdout is the whole answer.
    class Base
      def initialize(factory)
        @factory = factory
      end

      def call(context, args, opts)
        invocation = Invocation.new(command: self.class::NAME, request_id: request_id(opts))
        result = attempt(invocation, context, args, opts)
        emit(context, result, opts)
        result.exit_status
      end

      private

      def request_id(opts)
        Invocation.request_id(opts[:request_id])
      rescue Error => e
        raise CLI::UsageError, e.message
      end

      def attempt(invocation, context, args, opts)
        perform(invocation, @factory.call(context, opts), args, opts)
      rescue Error => e
        invocation.failure(e)
      rescue SignalException => e
        invocation.failure(Error.new("stopped by #{e.signm}", code: 'INTERRUPTED'))
      end

      def emit(context, result, opts)
        return context.puts(result.to_json_document(pretty: context.tty)) if opts[:json]
        return report_failure(context, result) unless result.ok

        render(context, result)
        unverified(context, result)
      end

      def report_failure(context, result)
        prefix = context.paint_err(:error, 'error:')
        context.warn("#{prefix} #{CLI::Style.plain(result.error[:message])} [#{result.error[:code]}]")
        result.next_steps.each { context.warn("next: #{CLI::Style.plain(it)}") }
      end

      def unverified(context, result)
        return if result.not_verified.empty?

        context.puts('', context.paint(:muted, "Not verified: #{result.not_verified.join(', ')}"))
      end

      def rows(context, entries)
        width = entries.map { it.first.size }.max
        entries.each do |label, value|
          context.puts("#{context.paint(:heading, label.ljust(width))}  #{CLI::Style.plain(value)}")
        end
      end
    end
  end
end
