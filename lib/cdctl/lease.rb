# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'socket'
require 'time'
require_relative 'cli/errors'
require_relative 'error'
require_relative 'lease/store'

module Cdctl
  # Exclusive ownership of input between programs on one machine.
  #
  # A lease never expires by itself. Time passing, a dead process or a quiet owner only make it a
  # suspected orphan; ending it takes an explicit takeover, which is logged and fences the old token
  # by generation. A late message from the old owner therefore cannot revive or end anything.
  #
  # This coordinates programs. It cannot stop the person at the keyboard, and input checks for that
  # separately.
  class Lease
    # Process facts the lease compares, kept apart so a test can describe any machine.
    Machine = Data.define(:host, :boot_id, :start_ticks_of)

    TOKEN = /\Acdl-(\d+)-([0-9a-f]{32})\z/
    TOKEN_VARIABLE = 'CDCTL_LEASE_TOKEN'
    # A silent owner is worth pointing out after this long, and nothing more happens because of it.
    QUIET_AFTER_SECONDS = 600
    MAX_TEXT = 200
    VALID_TEXT = /\A[[:print:]]+\z/
    START_TICKS_FIELD = 19
    ZOMBIE = 'Z'

    def self.for(runtime)
      new(directory: runtime.paths.lease_dir, machine: machine(runtime.proc_root))
    end

    def self.machine(proc_root)
      Machine.new(host: Socket.gethostname, boot_id: read_text(File.join(proc_root, 'sys/kernel/random/boot_id')),
                  start_ticks_of: ->(pid) { start_ticks(proc_root, pid) })
    end

    # comm can hold spaces and parentheses, so fields count from the last closing parenthesis. A
    # zombie has ended and only waits for its parent, so it answers as gone.
    def self.start_ticks(proc_root, pid)
      text = read_text(File.join(proc_root, pid.to_s, 'stat'))
      return nil unless text

      fields = text.rpartition(') ').last.split
      fields.first == ZOMBIE ? nil : fields[START_TICKS_FIELD]&.to_i
    end

    def self.read_text(path)
      File.read(path).strip
    rescue SystemCallError
      nil
    end
    private_class_method :read_text

    def initialize(directory:, machine:, clock: -> { Time.now })
      @store = Store.new(directory)
      @machine = machine
      @clock = clock
    end

    def status
      report(@store.read)
    rescue Store::Damaged => e
      { state: 'unknown', reason: e.message }
    end

    def acquire(owner:, purpose:, request_id:, holder_pid: nil, takeover: false, force: false, reason: nil)
      validate_text('owner', owner)
      validate_text('purpose', purpose)
      token = nil
      record = @store.locked do
        current = current_for_acquire(takeover:, force:, reason:, request_id:)
        refuse_acquire(current, takeover:, force:, reason:) if held?(current)
        token = new_token(current.fetch(:generation, 0) + 1)
        take(current, new_record(token, owner, purpose, holder_pid, request_id), request_id, reason)
      end
      [report(record), token]
    end

    def renew(token, request_id:)
      @store.locked { report(heartbeat(token, request_id)) }
    end

    # Releasing twice with the same token is one request delivered twice, so it answers as done and
    # changes nothing. The token stays recorded only until the next acquire.
    def release(token, request_id:)
      @store.locked do
        current = readable
        next [report(current), false] if current[:state] == 'free' && owns?(current, token)

        verified(current, token)
        record = current.merge(state: 'free', released_at: stamp, released_by: 'owner', last_request_id: request_id)
        log('release', record, request_id:)
        [report(@store.replace(record)), true]
      end
    end

    # What every send asks. It only reads, since it runs before each key press.
    def verify!(token)
      refuse_missing unless token
      verified(readable, token)
    end

    def touch(token, request_id:)
      @store.locked { heartbeat(token, request_id) }
    end

    private

    def take(current, fresh, request_id, reason)
      if held?(current)
        log('takeover', current, request_id:, by: fresh[:owner], reason:)
        fresh = fresh.merge(taken_from: current[:owner])
      end
      log('acquire', fresh, request_id:)
      @store.replace(fresh)
    end

    def heartbeat(token, request_id)
      @store.replace(verified(readable, token).merge(renewed_at: stamp, last_request_id: request_id))
    end

    def readable
      @store.read
    rescue Store::Damaged => e
      raise Error.new("the lease file cannot be read: #{e.message}", code: 'PRECONDITION_FAILED',
                                                                     next_steps: damaged_steps)
    end

    # Replacing a file nobody can read is a takeover like any other: explicit, explained and logged.
    # The generation goes on from the history, so an old token stays older than the new one.
    def current_for_acquire(takeover:, force:, reason:, request_id:)
      @store.read
    rescue Store::Damaged => e
      unless takeover && force
        raise Error.new("the lease file cannot be read: #{e.message}", code: 'LEASE_BUSY', next_steps: damaged_steps)
      end
      raise CLI::UsageError, '--takeover needs a --reason, which goes in the log' if reason.to_s.strip.empty?

      @store.log({ event: 'takeover', at: stamp, damaged: true, reason:, request_id: })
      { generation: @store.last_generation, state: 'free' }
    end

    def damaged_steps
      ['Once nothing is sending input, run cdctl lease acquire with --takeover --force and a --reason to replace it.']
    end

    def held?(record) = record[:state] == 'held'

    def refuse_acquire(current, takeover:, force:, reason:)
      assessed = report(current)
      return permit_takeover(assessed, force:, reason:) if takeover

      raise Error.new("#{current[:owner]} holds the lease: #{current[:purpose]}", code: 'LEASE_BUSY', data: assessed,
                                                                                  next_steps: busy_steps(assessed))
    end

    def permit_takeover(assessed, force:, reason:)
      raise CLI::UsageError, '--takeover needs a --reason, which goes in the log' if reason.to_s.strip.empty?
      return if force || assessed.dig(:orphan, :suspected)

      raise Error.new("#{assessed[:owner]} holds the lease and nothing suggests it is gone; --force overrides that",
                      code: 'LEASE_BUSY', data: assessed,
                      next_steps: ['Ask the owner to release it, or use --takeover --force if you are sure.'])
    end

    def busy_steps(assessed)
      reasons = assessed[:orphan][:reasons]
      return ['Ask the owner to release it, and check again with cdctl lease status.'] if reasons.empty?

      ["It looks orphaned (#{reasons.join(', ')}). Check that nothing is using it, then run cdctl lease acquire " \
       'with --takeover and a --reason.']
    end

    def verified(record, token)
      return record if held?(record) && owns?(record, token)

      raise Error.new(lost_message(record), code: 'LEASE_LOST', data: report(record),
                                            next_steps: ['Run cdctl lease status, and acquire it again if it is free.'])
    end

    def lost_message(record)
      return 'this token no longer holds the lease, which is free' unless held?(record)

      "this token no longer holds the lease, which #{record[:owner]} holds at generation #{record[:generation]}"
    end

    def owns?(record, token)
      token.to_s.match?(TOKEN) && Digest::SHA256.hexdigest(token) == record[:token_sha256]
    end

    def refuse_missing
      current = readable
      if held?(current)
        raise Error.new("sending input needs the lease, and #{current[:owner]} holds it: #{current[:purpose]}",
                        code: 'LEASE_BUSY', data: report(current),
                        next_steps: ['Wait for it, or see cdctl lease status.'])
      end

      raise Error.new('sending input needs a lease token', code: 'LEASE_REQUIRED',
                                                           next_steps: ['Run cdctl lease acquire and pass its token.'])
    end

    def new_token(generation) = "cdl-#{generation}-#{SecureRandom.hex(16)}"

    def new_record(token, owner, purpose, holder_pid, request_id)
      {
        generation: token[TOKEN, 1].to_i, state: 'held', owner:, purpose:, host: @machine.host,
        boot_id: @machine.boot_id, holder: holder(holder_pid), token_sha256: Digest::SHA256.hexdigest(token),
        acquired_at: stamp, renewed_at: stamp, last_request_id: request_id
      }.compact
    end

    def holder(pid)
      return nil unless pid

      ticks = @machine.start_ticks_of.call(pid)
      raise CLI::UsageError, "no process has PID #{pid}" unless ticks

      { pid:, start_ticks: ticks }
    end

    # What a caller may read: never the token or its hash.
    def report(record)
      return { state: 'free', generation: record.fetch(:generation, 0) }.merge(ended(record)) unless held?(record)

      age = @clock.call - Time.iso8601(record[:renewed_at])
      record.except(:token_sha256, :boot_id).merge(heartbeat_age_seconds: age.round(3), orphan: orphan(record, age))
    end

    def ended(record)
      { last_owner: record[:owner], released_at: record[:released_at], released_by: record[:released_by] }.compact
    end

    def orphan(record, age)
      reasons = []
      reasons << 'machine_restarted' if record[:boot_id] != @machine.boot_id
      reasons << 'holder_process_gone' if holder_gone?(record)
      reasons << 'owner_silent' if age > QUIET_AFTER_SECONDS
      { suspected: !reasons.empty?, reasons: }
    end

    def holder_gone?(record)
      held_by = record[:holder]
      held_by && @machine.start_ticks_of.call(held_by[:pid]) != held_by[:start_ticks]
    end

    def log(event, record, request_id:, **extra)
      line = { event:, at: stamp, generation: record[:generation], owner: record[:owner], request_id:, **extra }
      @store.log(line.compact)
    end

    def validate_text(name, value)
      return if value.is_a?(String) && value.size <= MAX_TEXT && VALID_TEXT.match?(value)

      raise CLI::UsageError, "invalid #{name} #{value.inspect}: use up to #{MAX_TEXT} printable characters"
    end

    def stamp = @clock.call.iso8601(3)
  end
end
