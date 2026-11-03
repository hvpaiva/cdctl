# frozen_string_literal: true

module Cdctl
  # Callers branch on these names, so a code is never renamed or reused for another meaning.
  # A code listed before a command can raise it reserves the name for that command.
  module ErrorCodes
    Category = Data.define(:exit_status, :result_status, :meaning)

    CATEGORIES = {
      failed: Category.new(exit_status: 1, result_status: 'failed',
                           meaning: 'The operation ran and did not reach its result.'),
      usage: Category.new(exit_status: 2, result_status: 'usage_error',
                          meaning: 'The command line is wrong. Nothing ran.'),
      precondition: Category.new(exit_status: 3, result_status: 'precondition_failed',
                                 meaning: 'The state of the game or machine does not allow the operation.'),
      unsupported: Category.new(exit_status: 4, result_status: 'unsupported',
                                meaning: 'This build, platform or backend does not support the operation.'),
      interrupted: Category.new(exit_status: 130, result_status: 'interrupted',
                                meaning: 'A signal stopped the operation.')
    }.freeze

    CODES = {
      'CAPTURE_FAILED' => [:failed, 'A capture could not be taken from the game window.'],
      'GAME_NOT_INSTALLED' => [:precondition, 'No Steam library holds the game.'],
      'GAME_NOT_RUNNING' => [:precondition, 'No game process is running.'],
      'FOCUS_LOST' => [:precondition, 'The game window lost focus during the operation.'],
      'INTERNAL_ERROR' => [:failed, 'An unexpected failure inside cdctl.'],
      'INTERRUPTED' => [:interrupted, 'A signal stopped the operation.'],
      'INVALID_CONFIG' => [:precondition, 'The configuration file cannot be used.'],
      'LEASE_BUSY' => [:precondition, 'Another owner holds the input lease.'],
      'NOT_IMPLEMENTED' => [:unsupported, 'This version of cdctl does not implement the command.'],
      'OBSERVATION_NOT_FOUND' => [:precondition, 'No stored observation has this id.'],
      'OBSERVATION_STALE' => [:precondition, 'The observation is older than the allowed age.'],
      'PRECONDITION_FAILED' => [:precondition, 'A condition the operation requires does not hold.'],
      'RESOLUTION_CHANGED' => [:precondition, 'The window, the display, a stored resolution or the HUD scale changed ' \
                                              'since the observation.'],
      'SYSTEM_DIALOG_PRESENT' => [:precondition, 'A system dialog covers the game, or may cover it.'],
      'TARGET_AMBIGUOUS' => [:precondition, 'More than one process or window matches the game.'],
      'TARGET_CHANGED' => [:precondition, 'The game process or window is not the observed one.'],
      'TIMEOUT' => [:failed, 'The operation did not finish in time.'],
      'UNKNOWN_SCREEN' => [:precondition, 'The current screen is not recognized.'],
      'UNSUPPORTED_BACKEND' => [:unsupported, 'The requested backend is not usable here.'],
      'UNSUPPORTED_BUILD' => [:unsupported, 'No UI profile supports this build, language or viewport.'],
      'UNSUPPORTED_PLATFORM' => [:unsupported, 'This operating system is not supported for the operation.'],
      'USAGE' => [:usage, 'The command line is wrong.'],
      'USER_INTERFERENCE' => [:precondition, 'Input from another source arrived during the operation.'],
      'VERIFY_FAILED' => [:failed, 'The action ran but its expected result was not observed.'],
      'WINDOW_NOT_FOUND' => [:precondition, 'The game runs but no usable window was found.']
    }.freeze

    def self.category(code) = CATEGORIES.fetch(CODES.fetch(code).first)

    def self.exit_statuses
      CATEGORIES.values.to_h { [it.exit_status, it.meaning] }.merge(0 => 'The operation reached its result.').sort.to_h
    end

    def self.catalog = CODES.map { |code, (category, meaning)| { code:, category:, meaning: } }
  end
end
