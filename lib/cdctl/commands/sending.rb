# frozen_string_literal: true

require_relative 'capturing'
require_relative 'lease'
require_relative '../driving'
require_relative '../input/session'
require_relative '../recognition/profile'
require_relative '../x11'

module Cdctl
  module Commands
    # What every command that sends something shares: one guarded session, and what happened so far
    # reported even when it ends in a failure.
    module Sending
      include Capturing
      include LeaseToken

      private

      def with_session(observer, runtime, invocation, snapshot, opts)
        Input::Session.open(**session_options(observer, runtime, invocation, snapshot, opts)) do |session|
          @under_way = [session, snapshot]
          yield session
        rescue Error => e
          raise e.record(actions: session.sender.actions, changed: changed_by(session), target: snapshot.target)
        rescue X11::Error => e
          raise x11_failure(e, session, snapshot)
        end
      end

      def so_far
        session, snapshot = @under_way
        return {} unless session

        { actions: session.sender.actions, changed: changed_by(session), target: snapshot.target }
      end

      # The answer must still say what had been sent by then, and what may be left behind.
      def x11_failure(error, session, snapshot)
        code = error.is_a?(X11::TimeoutError) ? 'TIMEOUT' : 'INPUT_FAILED'
        Error.new("the X server failed during the operation: #{error.message}", code:, target: snapshot.target,
                                                                                actions: session.sender.actions,
                                                                                changed: changed_by(session),
                                                                                next_steps: ['Run cdctl status, and ' \
                                                                                             'cdctl input release if ' \
                                                                                             'it says input was left ' \
                                                                                             'held.'])
      end

      def session_options(observer, runtime, invocation, snapshot, opts)
        process = snapshot.process
        { runtime:, connection: observer.connection, snapshot:, token: token_from(runtime, opts),
          allow_unverified: opts[:allow_unverified_dialogs], request_id: invocation.request_id,
          compositor: observer.compositor_probe(process), opener: observer.connection_opener(process) }
      end

      # Nothing sent changed nothing. Once something was sent, only a check can say what it did.
      def changed_by(session) = session.sender.actions.empty? ? false : nil

      # The profile for what is running, or why semantic commands cannot run here. Observation keeps
      # working without one, and so does low-level input.
      def profile_for(runtime, snapshot)
        installation = snapshot.installation
        window = snapshot.window
        return [nil, 'no window or installation to match a profile against'] unless installation && window

        Recognition::Profile.find(build: installation.build_id, language: installation.language, width: window.width,
                                  height: window.height,
                                  candidates: Recognition::Profile.all(runtime.paths.profiles_dir))
      end

      # A semantic command needs a screen it can name, and that is only ever known for a profile.
      def require_profile(runtime, snapshot)
        profile, reason = profile_for(runtime, snapshot)
        return profile if profile

        raise Error.new("no semantic command runs here: #{reason}", code: 'UNSUPPORTED_BUILD', target: snapshot.target,
                                                                    next_steps: ['cdctl input still works. Read the ' \
                                                                                 'capture yourself.'])
      end

      # Shortcuts differ between presets, so one the profile was not measured with is not assumed.
      def require_preset(profile, snapshot)
        options = snapshot.options
        fact = options.respond_to?(:keyboard_mouse_preset) ? options.keyboard_mouse_preset : nil
        return if fact&.known? && profile.keyboard_presets.include?(fact.value)

        raise Error.new('the keyboard preset in use was not tested with this profile', code: 'UNSUPPORTED_BUILD',
                                                                                       target: snapshot.target,
                                                                                       next_steps: ['cdctl input ' \
                                                                                                    'still works.'])
      end

      def hud_scale_of(snapshot)
        fact = snapshot.resolution[:hud_scale]
        fact.known? ? fact.value : nil
      end

      def eyes_for(observer, snapshot, profile)
        Driving::Eyes.new(connection: observer.connection, window: snapshot.window, profile:,
                          hud_scale: hud_scale_of(snapshot))
      end

      # The screen for observe, as a claim with its origin.
      def screen_fact(runtime, observer, snapshot)
        profile, reason = profile_for(runtime, snapshot)
        return Fact.unknown(reason) unless profile

        match = eyes_for(observer, snapshot, profile).look
        return Fact.unknown('nothing this profile knows is on the screen, which can be a loading screen') unless match

        Fact.known(match.to_h, source: 'visual_anchors', observed_at: Time.now.iso8601(3))
      rescue Error, X11::Error => e
        Fact.unknown(e.message)
      end
    end
  end
end
