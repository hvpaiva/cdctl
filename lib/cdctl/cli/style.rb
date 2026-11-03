# frozen_string_literal: true

module Cdctl
  module CLI
    class Style
      MODES = %w[auto always never].freeze
      DEFAULT_MODE = 'auto'
      FORCE_VARIABLES = %w[FORCE_COLOR CLICOLOR_FORCE].freeze
      ROLES = {
        heading: '1',
        success: '32',
        warning: '33',
        danger: '31',
        muted: '90;3',
        help_header: '1',
        help_flag: '36',
        help_command: '32',
        help_comment: '90;3',
        error: '31'
      }.freeze
      # C0 and C1 control characters, DEL, and the bidirectional controls: everything a terminal
      # would obey, or use to reorder a line, instead of show.
      CONTROL = /[\p{Cc}\p{Bidi_Control}]/
      REPLACEMENT = [0xFFFD].pack('U').freeze
      LAYOUT = "\t\n"

      def self.for(mode, tty:, env:) = new(enabled: enabled?(mode, tty:, env:))

      def self.enabled?(mode, tty:, env:)
        case mode
        when 'always' then true
        when 'never' then false
        else auto?(tty:, env:)
        end
      end

      def self.auto?(tty:, env:)
        return false if set?(env['NO_COLOR'])
        return true if FORCE_VARIABLES.any? { set?(env[it]) }
        return false if env['TERM'] == 'dumb'

        tty
      end

      def self.set?(value) = !value.to_s.empty?

      private_class_method :enabled?, :auto?, :set?

      def self.disabled = new(enabled: false)

      # Painting is how cdctl's own escape sequences reach a stream. Text from anywhere else, such
      # as a window title or a path, is made visible instead: C0 characters and DEL take caret
      # notation (ESC is ^[, DEL is ^?), the rest the replacement character. `layout` keeps line
      # feeds and tabs, for a message laid out on several lines such as "Did you mean this?".
      # Under the C locale Ruby hands ARGV, ENV and paths over as BINARY, which a UTF-8 pattern
      # cannot match; reading the bytes as UTF-8 keeps the valid ones and scrubs the rest.
      def self.plain(text, layout: false)
        String.new(text.to_s, encoding: Encoding::UTF_8).scrub.gsub(CONTROL) do |char|
          next char if layout && LAYOUT.include?(char)

          char.ord < 0x80 ? "^#{((char.ord + 0x40) & 0x7F).chr}" : REPLACEMENT
        end
      end

      def initialize(enabled:)
        @enabled = enabled
      end

      def enabled? = @enabled

      def paint(role, text)
        return text.to_s unless @enabled

        "\e[#{ROLES.fetch(role)}m#{text}\e[0m"
      end
    end
  end
end
