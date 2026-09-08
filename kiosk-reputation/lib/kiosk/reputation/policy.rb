# frozen_string_literal: true

module Kiosk
  module Reputation
    # Base policy class. Returns nil for every request (never challenge).
    #
    # Providers subclass this (or replace it wholesale) to implement their own
    # challenge logic. See {Policies::RateAndReputation} for a shipped example.
    #
    # @abstract
    class Policy
      # Decide whether to challenge the given request.
      #
      # @param identity [Object] opaque identity value from the host
      # @param verb     [Symbol] the coarse CALL KIND — one of :query, :run,
      #   :pay, and nothing else. This is the GATE's vocabulary, not the
      #   declaration vocabulary: a handler declared `kind :action` arrives
      #   here as :run. Branching on :action would match nothing and decline
      #   to toll every write in silence, so kiosk-server refuses such a
      #   policy at configuration time rather than running it.
      # @param factors  [Factors] reputation factors gathered by the host
      # @return [Hash{alg: String, params: Hash, count: Integer}] challenge spec
      #   to issue, or nil to serve without challenge. `count` (the N×PoW
      #   escalation lever — how many independent proofs to demand) is optional;
      #   the gate defaults it to 1 when omitted. Subclasses that escalate
      #   (see {Policies::RateAndReputation}) return `count`; the gate turns it
      #   into that many independent challenges.
      def challenge_for(identity:, verb:, factors:)
        nil
      end
    end
  end
end
