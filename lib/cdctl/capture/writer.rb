# frozen_string_literal: true

require 'digest'
require_relative '../error'
require_relative '../private_files'
require_relative 'png'

module Cdctl
  module Capture
    # Stores a shot and describes the file. Images are always files; a result never holds pixels.
    class Writer
      MAX_ZOOM = 8
      # A zoomed crop is for inspecting a small area, not for making a poster of the whole screen.
      MAX_ZOOMED_PIXELS = 16_000_000
      EVIDENCE_PATTERN = '[0-9]*T*Z-*.png'

      def initialize(paths:, settings:)
        @paths = paths
        @settings = settings
      end

      def write(shot, request_id:, output: nil, zoom: 1, pid: nil, window: nil)
        check_zoom(shot, zoom)
        path = output || default_path(request_id)
        png = Png.encode(shot.frame, zoom:)
        store(path, png, default: output.nil?)
        describe(shot, path, png, zoom, pid:, window:)
      end

      private

      def check_zoom(shot, zoom)
        fits = zoom.between?(1, MAX_ZOOM) && shot.frame.width * shot.frame.height * zoom * zoom <= MAX_ZOOMED_PIXELS
        return if fits || zoom == 1

        raise Error.new("zoom #{zoom} is not available for a #{shot.frame.width}x#{shot.frame.height} capture; " \
                        "use a smaller region and a zoom from 1 to #{MAX_ZOOM}", code: 'PRECONDITION_FAILED')
      end

      def default_path(request_id)
        File.join(@paths.evidence_dir, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{request_id}.png")
      end

      def store(path, png, default:)
        PrivateFiles.directory(File.dirname(path)) if default
        PrivateFiles.write(path, png)
        PrivateFiles.keep_newest(@paths.evidence_dir, EVIDENCE_PATTERN, @settings.evidence_keep) if default
      rescue SystemCallError => e
        raise Error.from_system_call(e, path, code: 'CAPTURE_FAILED')
      end

      def describe(shot, path, png, zoom, pid:, window:)
        {
          kind: 'screenshot', path:, bytes: png.bytesize, sha256: Digest::SHA256.hexdigest(png),
          width: shot.frame.width * zoom, height: shot.frame.height * zoom, zoom:, captured_at: shot.captured_at,
          backend: shot.backend, pid:, window: window&.hex_id, region: shot.region.to_h,
          absolute_region: shot.absolute, source_size: shot.source_size, pixel_scale: shot.pixel_scale,
          blank_suspected: shot.blank_suspected, fallback_reason: shot.fallback_reason
        }.compact
      end
    end
  end
end
