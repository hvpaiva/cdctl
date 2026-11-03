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
