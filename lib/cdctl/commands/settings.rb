# frozen_string_literal: true

require_relative 'base'
require_relative 'menu'
require_relative 'sending'
require_relative '../fact'
require_relative '../game/options_file'
require_relative '../observer'
require_relative '../recognition/profile'

module Cdctl
  module Commands
    # What the settings commands share: which settings a profile knows, and what the file says about
    # them. A setting is only as editable as what its profile saw work on the real game.
    module SettingsCatalog
      private

      def catalog_for(runtime, snapshot)
        installation = snapshot.installation or raise Error.new('the game is not installed', code: 'GAME_NOT_INSTALLED')
        profiles = Recognition::Profile.all(runtime.paths.profiles_dir)
        found = profiles.find { it.builds.include?(installation.build_id.to_s) && it.language == installation.language }
        return found if found

        raise Error.new("no profile covers build #{installation.build_id} in #{installation.language}",
                        code: 'UNSUPPORTED_BUILD',
                        next_steps: ['cdctl status still reports what the option file holds.'])
      end

      def read_options(snapshot)
        options = snapshot.options
        return options if options.respond_to?(:settings)

        raise Error.new("the option file cannot be read: #{options}", code: 'PRECONDITION_FAILED')
      end

      def definition(profile, name)
        profile.settings.fetch(name.to_sym) do
          raise CLI::UsageError, "no setting called #{name}; known settings: #{profile.settings.keys.join(', ')}"
        end
      end

      def describe_setting(name, setting, options)
        fact = options.value_of(setting[:option], setting[:attribute])
        {
          name: name.to_s, section: setting[:section], label: setting[:label], value: named_value(setting, fact),
          raw: fact.known? ? fact.value : nil, source: 'option_file', editable: !setting[:order].nil?,
          options: (setting[:values] || {}).keys.map(&:to_s)
        }
      end

      # The file omitting a field means something only where the profile saw what that is.
      def named_value(setting, fact)
        return nil unless fact.known?
        return fact.value unless setting[:values]

        setting[:values].find { |_name, value| value[:raw] == fact.value }&.first&.to_s
      end

      def planned_change(name, setting, options, target)
        current = describe_setting(name, setting, options)
        value = setting[:values]&.fetch(target.to_sym, nil)
        unless setting[:order] && value
          raise Error.new("#{name} cannot be set to #{target}: this profile can set " \
                          "#{setting[:order]&.join(' or ') || 'nothing on it'}", code: 'UNSUPPORTED_BUILD')
        end

        { setting: name.to_s, from: current[:value], to: target, raw_from: current[:raw], raw_to: value[:raw],
          file_change: { element: setting[:option], was: current[:raw], will_be: value[:raw] },
          label: setting[:label], restore: "cdctl settings set #{name} #{current[:value]} --apply --token TOKEN" }
      end
    end

    class SettingsList < Base
      include SettingsCatalog

      NAME = 'settings list'

      def self.command(factory)
        CLI::Command.new(
          name: 'list', summary: 'List the settings this build is known to have',
          description: 'List the settings a profile covers, with the value in the option file and whether cdctl can ' \
                       'change them. It reads the file and sends nothing, so the game can be closed.',
          options: [CLI::Option.new(long: 'section', argument: 'SECTION', description: 'Only this section, as input.')],
          examples: [CLI::Example.new(comment: 'What can be changed',
                                      command: 'settings list --section input --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, _args, opts)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          options = read_options(snapshot)
          listed = catalog_for(runtime, snapshot).settings.map { |name, it_is| describe_setting(name, it_is, options) }
          listed = listed.select { it[:section] == opts[:section] } if opts[:section]
          invocation.success(data: { settings: listed, file: options.path, modified_at: options.modified_at.iso8601 },
                             target: snapshot.target, not_verified: ['settings.value_in_the_running_game'])
        end
      end

      def render(context, result)
        rows(context, result.data[:settings].map do |setting|
          value = setting[:value] || setting[:raw] || 'not in the file'
          [setting[:name], "#{value}#{' (editable)' if setting[:editable]}"]
        end)
      end
    end

    class SettingsGet < Base
      include SettingsCatalog

      NAME = 'settings get'

      def self.command(factory)
        CLI::Command.new(
          name: 'get', summary: 'Read one setting',
          description: 'Read one setting from the option file. A value not yet applied in the menu is not there, and ' \
                       'a value in the file says what the game will read, not always what it uses right now.',
          positionals: [CLI::Positional.new(name: 'SETTING', description: 'Its name, as settings list shows it.')],
          examples: [CLI::Example.new(comment: 'Read the keyboard preset',
                                      command: 'settings get keyboard_mouse_preset --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, args, _opts)
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          profile = catalog_for(runtime, snapshot)
          data = describe_setting(args.first, definition(profile, args.first), read_options(snapshot))
          invocation.success(data:, target: snapshot.target, not_verified: ['settings.value_in_the_running_game'])
        end
      end

      def render(context, result)
        rows(context, [['Setting', result.data[:name]], ['Value', result.data[:value] || 'unknown'],
                       ['In the file', result.data[:raw] || 'not in the file'],
                       ['Options', result.data[:options].join(', ')]])
      end
    end

    class SettingsPlan < Base
      include SettingsCatalog

      NAME = 'settings plan'

      def self.command(factory)
        CLI::Command.new(
          name: 'plan', summary: 'Say what setting a value would change, and send nothing',
          description: 'Say what a change would do to the option file and how to undo it, and send nothing. ' \
                       'cdctl settings set compares the real result with this.',
          positionals: [CLI::Positional.new(name: 'SETTING=VALUE',
                                            description: 'What to change, as keyboard_mouse_preset=classic.')],
          examples: [CLI::Example.new(comment: 'Before a change',
                                      command: 'settings plan keyboard_mouse_preset=standard --json')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, args, _opts)
        name, target = args.first.split('=', 2)
        raise CLI::UsageError, "expected SETTING=VALUE, got #{args.first.inspect}" if target.to_s.empty?

        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          profile = catalog_for(runtime, snapshot)
          plan = planned_change(name, definition(profile, name), read_options(snapshot), target)
          invocation.success(data: plan.merge(needed: plan[:from] != target), target: snapshot.target)
        end
      end

      def render(context, result)
        rows(context, [['Setting', result.data[:setting]], ['From', result.data[:from].to_s], ['To', result.data[:to]],
                       ['Undo', result.data[:restore]]])
      end
    end

    class SettingsSet < DrivingBase
      include SettingsCatalog

      NAME = 'settings set'
      VALUE_TIMEOUT = 10.0
      FILE_TIMEOUT = 15.0
      # The game was seen to take a moment over its writes, so a file has to hold still this long.
      FILE_QUIET = 1.0
      UNCERTAIN = 'The confirmation was sent, so this may have been applied. Read the value with cdctl settings get.'
      POLL = 0.2
      DESCRIPTION = 'Reach the setting in the menu, change that one row, confirm the dialog once it is recognized, ' \
                    "and compare the option file with the plan. Any other difference answers VERIFY_FAILED.\n\n" \
                    'Without --apply it sends nothing and only says what it would do. The answer holds the command ' \
                    'that undoes the change.'
      # One change: what is being set, and what the file held before it.
      Change = Data.define(:setting, :plan, :options)

      def self.command(factory)
        CLI::Command.new(
          name: 'set', summary: 'Change one setting through the menu, and prove only it changed',
          description: DESCRIPTION,
          positionals: [CLI::Positional.new(name: 'SETTING', description: 'Its name, as settings list shows it.'),
                        CLI::Positional.new(name: 'VALUE', description: 'The value, as settings list shows it.')],
          options: [CLI::Option.new(long: 'apply', description: 'Really do it.'),
                    CLI::Option.new(long: 'verify', description: 'Compare with the file, which always happens.'),
                    *COMMON_OPTIONS],
          examples: [CLI::Example.new(comment: 'Change a preset',
                                      command: 'settings set keyboard_mouse_preset standard --apply --token TOKEN')],
          handler: new(factory)
        )
      end

      private

      def perform(invocation, runtime, args, opts)
        @timeout = bounded_timeout(opts[:timeout])
        Observer.open(runtime) do |observer|
          snapshot = observer.snapshot
          change = change_from(runtime, snapshot, args)
          needed = change.plan[:from] != change.plan[:to]
          next dry_run(invocation, snapshot, change.plan, needed) unless opts[:apply]
          next already(invocation, snapshot, change.plan) unless needed

          snapshot.require_window!
          driving(invocation, runtime, observer, snapshot, opts) { apply(it, observer, change) }
        end
      end

      def change_from(runtime, snapshot, args)
        setting = definition(catalog_for(runtime, snapshot), args.first)
        options = read_options(snapshot)
        Change.new(setting:, options:, plan: planned_change(args.first, setting, options, args.last))
      end

      def dry_run(invocation, snapshot, plan, needed)
        invocation.success(data: plan.merge(applied: false, needed:), target: snapshot.target)
      end

      def already(invocation, snapshot, plan)
        invocation.success(data: plan.merge(applied: false, needed: false, real_changes: []), target: snapshot.target,
                           changed: false, before: { value: plan[:from] }, after: { value: plan[:from] },
                           verification: { method: 'option_file', expected: plan[:to], observed: plan[:from] })
      end

      def apply(turn, observer, change)
        navigator = turn.navigator
        eyes = eyes_for(observer, turn.snapshot, require_profile(turn.runtime, turn.snapshot))
        navigator.go_to(change.setting.fetch(:screen))
        check_row(navigator, eyes, change)
        changes = with_the_row_accounted_for(change) do
          change_row(navigator, eyes, change)
          confirm_and_compare(navigator, change)
        end
        back_on_the_screen(navigator, change, changes)
        report(turn, change, changes)
      end

      # A list can scroll, and two rows can show the same value, so the row itself has to be where the
      # point is before anything is clicked.
      def check_row(navigator, eyes, change)
        setting = change.setting
        plan = change.plan
        unless navigator.on_screen?([setting.fetch(:row)])
          raise Error.new("the row of #{plan[:setting]} is not where this profile expects it, so nothing was changed",
                          code: 'UNKNOWN_SCREEN', next_steps: ['Read the capture with cdctl observe.'])
        end
        return if eyes.sees?(setting.fetch(:values).fetch(plan[:from].to_sym).fetch(:anchor))

        raise Error.new("the menu does not show #{plan[:from]}, which the option file says it should, so nothing " \
                        'was changed', code: 'VERIFY_FAILED', next_steps: ['Read the capture with cdctl observe.'])
      end

      # Once the row moved, a failure can leave it showing a value that was never applied, and repeating
      # the command would then not find what it expects. Once the confirmation went out, the game may
      # have taken it or not, and only the file can say. The answer has to tell these apart.
      def with_the_row_accounted_for(change)
        @confirmation_sent = false
        yield
      rescue Error => e
        raise if e.data

        plan = change.plan
        if @confirmation_sent
          raise e.attach(data: plan.merge(applied: nil, confirmation_sent: true), next_steps: [UNCERTAIN])
        end

        raise e.attach(data: plan.merge(applied: false, row_left_pending: true),
                       next_steps: ["The row may show #{plan[:to]} with nothing applied. Read the capture before " \
                                    'anything else.'])
      end

      def change_row(navigator, eyes, change)
        setting = change.setting
        plan = change.plan
        order = setting.fetch(:order)
        navigator.click(setting.fetch(order.index(plan[:to]) > order.index(plan[:from]) ? :next : :previous))
        wait_for_value(navigator, eyes, setting.fetch(:values).fetch(plan[:to].to_sym), plan)
      end

      def wait_for_value(navigator, eyes, value, plan)
        deadline = monotonic + VALUE_TIMEOUT
        loop do
          navigator.pause_a_moment
          return if eyes.sees?(value.fetch(:anchor))

          if monotonic > deadline
            raise Error.new("the row did not change to #{plan[:to]}", code: 'VERIFY_FAILED',
                                                                      next_steps: ['Read the capture.'])
          end
        end
      end

      def confirm_and_compare(navigator, change)
        confirm = change.setting.fetch(:confirm)
        navigator.settle
        navigator.send_key(confirm)
        navigator.wait_for([change.setting.fetch(:dialog)])
        navigator.settle
        @confirmation_sent = true
        navigator.send_key(confirm)
        changes = await_file(change)
        compare(changes, change)
        changes
      end

      # The file is the proof, and the game writes it some time after the dialog closes, maybe more than
      # once. Only what has stayed the same for a moment is compared. A file caught in the middle of being
      # written, or not changed yet, is simply not the answer yet.
      def await_file(change)
        deadline = monotonic + FILE_TIMEOUT
        seen = nil
        since = monotonic
        loop do
          changes = differences_now(change.options)
          return changes if changes == seen && changes&.any? && monotonic - since >= FILE_QUIET

          unless changes == seen
            seen = changes
            since = monotonic
          end
          raise file_did_not_settle(change) if monotonic > deadline

          sleep(POLL)
        end
      end

      def file_did_not_settle(change)
        Error.new("the option file did not change after applying #{change.plan[:to]}, or did not stop changing",
                  code: 'VERIFY_FAILED', next_steps: ['Read the capture.'])
      end

      def differences_now(earlier)
        Game::OptionsFile.read(earlier.path).changes_since(earlier)
      rescue Game::OptionsFile::ParseError
        nil
      end

      def compare(changes, change)
        setting = change.setting
        only = changes.one? ? changes.first : nil
        return if only && only[:setting].end_with?("/#{setting[:option]}") &&
                  only[:now]&.fetch(setting[:attribute], nil) == change.plan[:raw_to]

        raise Error.new("the real change is not the planned one: #{changes.size} setting(s) changed in the file",
                        code: 'VERIFY_FAILED', data: { plan: change.plan, real_changes: changes },
                        next_steps: ["To undo: #{change.plan[:restore]}"])
      end

      # Past this point the change happened and was proved, and whatever goes wrong has to say so.
      def back_on_the_screen(navigator, change, changes)
        navigator.wait_for([change.setting.fetch(:screen)])
      rescue Error => e
        raise e.attach(data: change.plan.merge(applied: true, real_changes: changes),
                       next_steps: ["The change was applied and proved. To undo: #{change.plan[:restore]}"])
      end

      def report(turn, change, changes)
        plan = change.plan
        Observer.open(turn.runtime) do |later|
          fresh = later.snapshot
          artifact = capture_if_possible(later, turn.runtime, fresh, turn.invocation)
          turn.invocation.success(
            data: plan.merge(applied: true, needed: true, real_changes: changes, **sent_so_far(turn, fresh)),
            target: fresh.target || turn.snapshot.target, changed: true, actions: turn.session.sender.actions,
            before: { value: plan[:from] }, after: { value: plan[:to] },
            verification: proof(plan, artifact, changes), artifacts: [artifact].compact,
            not_verified: (with_the_screen_known(notes_on(fresh, artifact)) + turn.session.not_verified).uniq,
            next_steps: ["To undo: #{plan[:restore]}"]
          )
        end
      end

      def sent_so_far(turn, fresh)
        { modals: fresh.modals, activity: turn.session.activity_report, steps: turn.navigator.steps_taken }
      end

      def proof(plan, artifact, changes)
        { method: 'option_file', screenshot: artifact&.fetch(:path, nil), expected: plan[:file_change],
          observed: changes }.compact
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def render(context, result)
        rows(context, [['Setting', result.data[:setting]], ['From', result.data[:from].to_s], ['To', result.data[:to]],
                       ['Applied', result.data[:applied].to_s], ['Undo', result.data[:restore]]])
      end
    end

    module SettingsCommands
      def self.command(factory)
        CLI::Command.new(
          name: 'settings', section: 'Control Commands', summary: 'Read and change settings, with proof',
          subcommands: [SettingsList, SettingsGet, SettingsPlan, SettingsSet].map { it.command(factory) }
        )
      end
    end
  end
end
