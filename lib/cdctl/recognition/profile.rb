# frozen_string_literal: true

require 'json'
require_relative '../fact'
require_relative 'signature'

module Cdctl
  module Recognition
    # One place on the screen and what it looks like there. The rectangle is in fractions of the
    # window height, so one profile covers every resolution of its aspect ratio.
    Anchor = Data.define(:name, :rect, :grid, :channel, :signature, :minimum) do
      def box(frame)
        scale = frame.height
        x, y, width, height = rect.map { (it * scale).round }
        [x.clamp(0, frame.width - 1), y.clamp(0, frame.height - 1), width.clamp(1, frame.width - x),
         height.clamp(1, frame.height - y)]
      end

      def score(frame) = Signature.correlation(signature, Signature.of(frame, box(frame), grid, channel))

      def matches?(frame) = score(frame) >= minimum
    end

    # What recognition found: a screen, and how sure each of its anchors was.
    Match = Data.define(:name, :score, :anchors) do
      def to_h = { name:, score: score.round(3), anchors: anchors.to_h { |key, value| [key.to_s, value.round(3)] } }
    end

    # Which screens exist in one build and language and how to tell them apart, plus what is known
    # about moving between them. Nothing here is a screenshot: the signatures are small grids of
    # averages, and every route was observed on the real game.
    class Profile
      DIRECTORY = File.expand_path('../profiles', __dir__)
      ASPECT_TOLERANCE = 0.01

      attr_reader :id, :builds, :language, :aspect, :hud_scale, :ui_scale, :keyboard_presets, :screens, :transitions,
                  :points, :flows, :settings

      # What ships with cdctl, plus what this machine taught it, which comes first. A file that
      # cannot be read is skipped: it is no reason to lose the others.
      def self.all(extra_directory = nil)
        [extra_directory, DIRECTORY].compact.flat_map do |directory|
          Dir.glob('*.json', base: directory).sort.filter_map { load(File.join(directory, it)) }
        end
      end

      def self.load(path)
        new(JSON.parse(File.read(path), symbolize_names: true))
      rescue SystemCallError, JSON::ParserError, KeyError, TypeError, NoMethodError
        nil
      end

      # The profile for this game, or why there is none. Only the combinations in a profile were ever
      # checked against the game, so anything else answers with the reason and no guess.
      def self.find(build:, language:, width:, height:, candidates: all)
        same_build = candidates.select { it.builds.include?(build.to_s) }
        return [nil, "no profile covers build #{build}"] if same_build.empty?

        same_language = same_build.select { it.language == language }
        return [nil, "no profile covers build #{build} in #{language}"] if same_language.empty?

        fitting = same_language.find { it.fits?(width, height) }
        fitting ? [fitting, nil] : [nil, "no profile covers a #{width}x#{height} window in build #{build}"]
      end

      def initialize(fields)
        @id = fields.fetch(:id)
        @builds = fields.fetch(:builds)
        @language = fields.fetch(:language)
        @aspect = fields.fetch(:aspect)
        @hud_scale = fields[:hud_scale]
        @ui_scale = fields[:ui_scale]
        @keyboard_presets = fields.fetch(:keyboard_presets)
        @anchors = fields.fetch(:anchors).to_h { |name, value| [name.to_s, anchor(name.to_s, value)] }
        @screens = fields.fetch(:screens)
        @transitions = fields.fetch(:transitions, [])
        @points = fields.fetch(:points, {})
        @flows = fields.fetch(:flows, {})
        @settings = fields.fetch(:settings, {})
      end

      def fits?(width, height)
        ((width.to_f / height) - (aspect.first.to_f / aspect.last)).abs < ASPECT_TOLERANCE
      end

      def screen_names = screens.map { it[:name] }

      def anchor_named(name) = @anchors.fetch(name)

      # A point on the screen by name, in pixels of a window of this height.
      def point(name, frame_height)
        x, y = points.fetch(name.to_sym)
        [(x * frame_height).round, (y * frame_height).round]
      end

      def anchor(name, value)
        Anchor.new(name:, rect: value.fetch(:rect), grid: value.fetch(:grid), channel: value.fetch(:channel),
                   signature: value.fetch(:signature), minimum: value.fetch(:minimum))
      end
      private :anchor
    end

    # Names what is on a frame. The first screen in the profile's order with all of its anchors above
    # their minimum wins, so a dialog comes before the menu it covers. No match is an answer too.
    # A screen known only by the HUD needs the HUD scale the profile was measured with.
    class Recognizer
      def initialize(profile, hud_scale: nil)
        @profile = profile
        @hud_scale = hud_scale
      end

      def recognize(frame)
        usable_screens.each do |screen|
          scores = {}
          matched = screen[:anchors].all? do |anchor_name|
            anchor = @profile.anchor_named(anchor_name)
            scores[anchor_name] = anchor.score(frame)
            scores[anchor_name] >= anchor.minimum
          end
          return Match.new(name: screen[:name], score: scores.values.min, anchors: scores) if matched
        end
        nil
      end

      private

      def usable_screens
        @profile.screens.reject { it[:hud] && !@hud_scale.nil? && @hud_scale != @profile.hud_scale }
      end
    end
  end
end
