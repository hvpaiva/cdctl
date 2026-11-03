# frozen_string_literal: true

module Cdctl
  module Commands
    # The human form of a snapshot. It reads the same data the JSON form prints, so the two cannot
    # disagree about a fact.
    module SnapshotView
      ABSENT = 'not in the file'

      module_function

      def rows(data)
        [
          ['Installation', installation(data[:installation])],
          ['Build', build(data[:installation])],
          ['Game', game(data[:game])],
          ['X11', x11(data[:x11])],
          ['Window', window(data[:window])],
          ['Compositor', compositor(data[:compositor])],
          ['System dialogs', modals(data[:modals])],
          *resolution(data[:resolution])
        ]
      end

      def installation(value)
        return value[:state].tr('_', ' ') unless value[:state] == 'found'

        "#{value[:name]} in #{value[:install_dir]}"
      end

      def build(value)
        return 'unknown' unless value[:state] == 'found'

        version = value[:version]
        text = version.known? ? version.value : 'version unknown'
        "#{text} (Steam build #{value[:build_id]}, #{value[:language] || 'language unknown'}, " \
          "Proton #{value[:proton_version] || 'unknown'})"
      end

      def game(value)
        return state_line(value) unless value[:state] == 'running'

        nested = value[:nested_compositor] ? ', inside a nested compositor' : ''
        "running as PID #{value[:pid]} since #{value[:started_at]}#{nested}"
      end

      def x11(value)
        return "#{value[:status].tr('_', ' ')}: #{value[:reason]}" unless value[:status] == 'connected'

        "connected to #{value[:display]}"
      end

      def window(value)
        return state_line(value) unless value[:state] == 'found'

        marks = [value[:focused] ? 'focused' : 'not focused', ('fullscreen' if value[:fullscreen])].compact
        "#{value[:id]} #{value[:width]}x#{value[:height]}+#{value[:x]}+#{value[:y]} #{marks.join(', ')}"
      end

      def state_line(value) = [value[:state].tr('_', ' '), value[:reason]].compact.join(': ')

      def lease(value)
        return state_line(value) unless value[:state] == 'held'

        orphan = value[:orphan][:suspected] ? ", suspected orphan (#{value[:orphan][:reasons].join(', ')})" : ''
        "held by #{value[:owner]}: #{value[:purpose]}#{orphan}"
      end

      def compositor(value)
        return "none known: #{value[:reason]}" unless value[:status] == 'available'

        where = value[:monitor] ? ", game on #{value[:monitor]}" : ''
        "#{value[:name]} #{value[:version]}#{where}"
      end

      def modals(value)
        case value[:status]
        when 'clear' then 'none'
        when 'present' then "present: #{value[:blocking].map { it[:namespace] }.join(', ')}"
        when 'unverified' then "not verified: #{value[:reason]}"
        else "cannot see them: #{value[:reason]}"
        end
      end

      # The file omitting a field says nothing about its value, so no default is named here.
      def resolution(value)
        [
          ['Display mode', fact(value[:display_mode]) { mode(it) }],
          ['Game screen', fact(value[:game_screen]) { mode(it) }],
          ['Window size', fact(value[:window]) { size(it) }],
          ['Capture', fact(value[:capture]) { size(it) }],
          ['Stored resolution', fact(value[:configured_override]) { it ? size(it) : ABSENT }],
          ['Active resolution', fact(value[:active])],
          ['Render scale', fact(value[:render_scale]) { it || ABSENT }],
          ['HUD scale', fact(value[:hud_scale]) { it || ABSENT }],
          ['Presentation', fact(value[:presentation]) { it[:mode] }],
          ['Coherence', fact(value[:coherence]) { it[:state] }]
        ]
      end

      def size(value) = "#{value[:width]}x#{value[:height]}"

      def mode(value)
        refresh = value[:refresh_hz] ? "@#{value[:refresh_hz]}" : ''
        "#{size(value)}#{refresh} (#{value[:output] || 'unnamed'})"
      end

      def fact(value)
        return "#{value.status}: #{value.reason}" unless value.known?

        text = block_given? ? yield(value.value) : value.value
        "#{text} [#{value.source}#{', inferred' if value.confidence == 'inferred'}]"
      end
    end
  end
end
