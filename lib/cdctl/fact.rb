# frozen_string_literal: true

module Cdctl
  # One thing cdctl claims, with where the claim comes from. `known` with a nil value means the
  # source was read and holds nothing, which differs from `unknown`: an option file without the
  # field is a fact about the file, and says nothing about the running game.
  Fact = Data.define(:status, :value, :source, :confidence, :reason, :observed_at) do
    def self.known(value, source:, confidence: 'observed', observed_at: nil)
      new(status: 'known', value:, source:, confidence:, reason: nil, observed_at:)
    end

    def self.unknown(reason) = blank('unknown', reason)

    def self.unsupported(reason) = blank('unsupported', reason)

    def self.blank(status, reason)
      new(status:, value: nil, source: nil, confidence: nil, reason:, observed_at: nil)
    end
    private_class_method :blank

    def known? = status == 'known'

    def to_h
      head = known? ? { status:, value: } : { status: }
      head.merge(super.slice(:source, :confidence, :reason, :observed_at).compact)
    end
  end
end
