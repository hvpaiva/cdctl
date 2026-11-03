# frozen_string_literal: true

require_relative 'base'
require_relative 'capturing'

module Cdctl
  module Commands
    class Screenshot < Base
      include Capturing

      NAME = 'screenshot'
      TARGETS = %w[game].freeze

      def self.command(factory)
        CLI::Command.new(
          name: NAME, section: 'Observation Commands', summary: 'Capture the game window to a PNG file',
          description: 'Capture the game window, never the desktop, and report the real size in pixels, the region, ' \
                       "the window, the process, the time and a hash. The image is always a file.\n\n" \
                       "With a system dialog over the game it stops and answers SYSTEM_DIALOG_PRESENT.\n\n" \
                       'A file written under the state directory is pruned; one named with --output is yours.',
          options: options,
          examples: [
            CLI::Example.new(comment: 'Capture the whole window', command: 'screenshot --json'),
            CLI::Example.new(comment: 'Inspect a corner at 4x, repeating pixels',
                             command: 'screenshot --region 0,650,500,430 --zoom 4 --output /tmp/corner.png --json')
          ],
          handler: new(factory)
        )
      end

      def self.options
        [CLI::Option.new(long: 'target', argument: 'TARGET', enum: TARGETS, default: 'game',
                         description: 'What to capture.'),
         CLI::Option.new(long: 'output', short: 'o', argument: 'PATH', description: 'Where to write the PNG.'),
         CLI::Option.new(long: 'region', argument: 'X,Y,WIDTH,HEIGHT',
                         description: 'A rectangle in window pixels. Coordinates from an older capture are valid ' \
                                      'only while cdctl observation check accepts that observation.'),
         CLI::Option.new(long: 'zoom', argument: 'N', default: '1',
                         description: 'Repeat each pixel N times, from 1 to 8. No pixel is invented.'),
         CLI::Option.new(long: 'backend', argument: 'NAME', enum: Capture::Service::BACKENDS, default: 'auto',
                         description: 'How to capture. auto tries X11 first.')]
      end
      private_class_method :options

      private

      def perform(invocation, runtime, _args, opts)
        region = opts[:region] && Capture::Region.parse(opts[:region])
        zoom = zoom_value(opts[:zoom])
        output = output_path(opts[:output])
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          artifact = capture(observer, runtime, snapshot, invocation, region:, zoom:, output:, backend: opts[:backend])
          resolution = snapshot.with_capture(artifact).resolution
          invocation.success(data: { path: artifact[:path], modals: snapshot.modals, resolution: },
                             target: snapshot.target, artifacts: [artifact],
                             not_verified: capture_notes(snapshot, artifact))
        end
      end

      def zoom_value(text)
        Integer(text, 10)
      rescue ArgumentError
        raise CLI::UsageError, "invalid zoom #{text.inspect}: expected a whole number from 1 to 8"
      end

      def output_path(text)
        text && File.expand_path(text)
      rescue ArgumentError => e
        raise CLI::UsageError, "invalid output path #{text.inspect}: #{e.message}"
      end

      def render(context, result)
        artifact = result.artifacts.first
        rows(context, [['File', artifact[:path]], ['Size', "#{artifact[:width]}x#{artifact[:height]}"],
                       ['Backend', artifact[:backend]], ['SHA-256', artifact[:sha256]]])
      end
    end
  end
end
