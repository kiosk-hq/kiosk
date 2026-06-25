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
      # @param verb     [Symbol] the Kiosk verb being requested (:query, :run, :pay, …)
      # @param factors  [Factors] reputation factors gathered by the host
      # @return [Hash{alg: String, params: Hash}] challenge spec to issue, or nil to serve
      def challenge_for(identity:, verb:, factors:)
        nil
      end
    end
  end
end
