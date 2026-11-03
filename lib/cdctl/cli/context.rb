# frozen_string_literal: true

require 'io/console'
require_relative 'style'

module Cdctl
  module CLI
    # Color is decided for stdout and stderr apart. A stream whose reader went away is remembered
    # and its later output dropped, so a command finishes its work when `head` exits or a wrapper
    # closed stderr.
    class Context
      attr_reader :out, :err, :env, :tty, :err_tty, :style, :err_style

      def self.system
        new(out: $stdout, err: $stderr, env: ENV.to_h, tty: $stdout.tty?, err_tty: $stderr.tty?)
      end

      def initialize(out:, err:, env: {}, tty: false, err_tty: false,
                     style: Style.disabled, err_style: Style.disabled)
        @out = out
        @err = err
        @env = env
        @tty = tty
        @err_tty = err_tty
        @style = style
        @err_style = err_style
        @closed = {}
      end

      # The copy shares this context's memory of closed streams.
      def with_color(mode)
        dup.tap { it.restyle(Style.for(mode, tty:, env:), Style.for(mode, tty: err_tty, env:)) }
      end

      def puts(*lines) = write(:out) { out.puts(*lines) }

      def print(*parts) = write(:out) { out.print(*parts) }

      def warn(*lines) = write(:err) { err.puts(*lines) }

      def paint(role, text) = style.paint(role, text)

      def paint_err(role, text) = err_style.paint(role, text)

      def columns
        from_env = Integer(env['COLUMNS'].to_s, 10, exception: false)
        return from_env if from_env&.positive?
        return nil unless tty && out.respond_to?(:winsize)

        width = out.winsize[1]
        width.positive? ? width : nil
      rescue SystemCallError
        nil
      end

      protected

      def restyle(style, err_style)
        @style = style
        @err_style = err_style
      end

      private

      def write(stream)
        return if @closed[stream]

        yield
      rescue Errno::EPIPE
        @closed[stream] = true
      end
    end
  end
end
