# frozen_string_literal: true

module Kiosk
  module Reputation
    # Immutable bundle of reputation factors the host populates per request.
    #
    # All fields are nullable — the provider decides which ones to track and
    # supply. A policy must handle nil gracefully (e.g. via `.to_i` which
    # returns 0 for nil).
    #
    # == Field semantics
    # - kyc_level              [nil|:basic|:verified]   KYC verification level
    # - settled_purchases_count [nil|Integer]           number of completed purchases
    # - settled_purchases_cents [nil|Integer]           total purchase value in cents
    # - request_rate_per_min   [nil|Numeric]            recent request rate (req/min)
    # - account_age_seconds    [nil|Integer]            seconds since account creation
    # - dispute_count          [nil|Integer]            number of disputes filed
    # - bad_proof_count        [nil|Integer]            number of invalid PoW proofs submitted
    #                                                   (clear bad-faith signal; policy escalates on it)
    #
    # == Usage
    #   Factors.new(request_rate_per_min: 42, settled_purchases_count: 0)
    #   Factors.empty   # all fields nil
    Factors = Data.define(
      :kyc_level,
      :settled_purchases_count,
      :settled_purchases_cents,
      :request_rate_per_min,
      :account_age_seconds,
      :dispute_count,
      :bad_proof_count
    ) do
      # Construct a Factors instance with all fields set to nil.
      # Use this as a safe default when the host has not yet wired up factor gathering.
      def self.empty
        new(
          kyc_level:               nil,
          settled_purchases_count: nil,
          settled_purchases_cents: nil,
          request_rate_per_min:    nil,
          account_age_seconds:     nil,
          dispute_count:           nil,
          bad_proof_count:         nil
        )
      end
    end
  end
end
