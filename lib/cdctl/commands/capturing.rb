# frozen_string_literal: true

require_relative '../capture/service'
require_relative '../capture/writer'
require_relative '../observer'

module Cdctl
  module Commands
    # What every command that takes a capture shares: the refusals before it, and what its result
    # can and cannot claim about the frame.
    module Capturing
      private

      def capture(observer, runtime, snapshot, invocation, region: nil, backend: 'auto', output: nil, zoom: 1)
        window = snapshot.require_capturable!
        service = Capture::Service.new(connection: observer.connection, shell: runtime.shell,
                                       guard: observer.screen_guard(snapshot.process))
        shot = service.take(window, region:, backend:)
        Capture::Writer.new(paths: runtime.paths, settings: runtime.settings)
                       .write(shot, request_id: invocation.request_id, output:, zoom:,
                                    pid: snapshot.process.pid, window:)
      end

      # After an action: the action happened whether or not a capture can follow it, as with a dialog
      # that opened meanwhile or a game that closed, so a failure here is no failure of the command.
      def capture_if_possible(observer, runtime, snapshot, invocation)
        capture(observer, runtime, snapshot, invocation)
      rescue Error
        nil
      end

      def notes_on(snapshot, artifact) = artifact ? capture_notes(snapshot, artifact) : snapshot.not_verified

      # A snapshot cannot say what is on the screen. An answer that recognized it can.
      def with_the_screen_known(notes) = notes - ['game.screen']

      # Without a compositing manager, X leaves the contents of a covered part of a window undefined,
      # and in practice returns whatever covers it.
      def capture_notes(snapshot, artifact)
        notes = snapshot.not_verified
        notes += ['capture.frame_is_current'] unless snapshot.window.focused
        notes += ['capture.only_the_game'] if read_from_x11?(artifact) && !snapshot.x11[:compositing_manager]
        notes += ['capture.frame_is_not_blank'] if artifact[:blank_suspected]
        notes
      end

      def read_from_x11?(artifact) = artifact[:backend] == Capture::Service::X11_BACKEND
    end
  end
end
