# frozen_string_literal: true

module Kiosk
  module Reputation
    module Policies
      # EXAMPLE policy — providers are expected to REPLACE this wholesale.
      #
      # This is the shipped illustrative policy for the "scrape-vs-buy" pattern
      # on a read-heavy endpoint. Its thresholds and d-curve are opinionated
      # defaults; tune them or write a domain-specific subclass instead.
      #
      # == Logic
      #
      # Serve without challenge when ALL of:
      #   - settled_purchases_count >= proven_purchases_threshold (principal has paid)
      #   - request_rate_per_min   <= low_rate_threshold          (not flooding)
      #   - bad_proof_count        == 0                          (no bad-faith history)
      #
      # Otherwise issue an Argon2id challenge at difficulty `d`, where `d` is
      # computed as:
      #
      #   d = base_d
      #     + ceil((rate - low_rate_threshold) / rate_step) * rate_d_step   [if rate > threshold]
      #     + unproven_d_bonus                                               [if 0 purchases]
      #     + bad_proof_count * bad_proof_d_factor                           [bad-faith escalation]
      #   d = d.clamp(d_min, d_max)
      #
      # The `bad_proof_d_factor` is intentionally high so that a few invalid
      # proofs push a principal into a hard challenge tier quickly. An honest
      # client solver never submits a wrong proof.
      #
      # == Constructor params (all have sane defaults)
      # @param proven_purchases_threshold [Integer]  min settled purchases to be "proven"
      # @param low_rate_threshold         [Integer]  max req/min considered low-rate
      # @param base_d                     [Integer]  starting difficulty when challenging
      # @param rate_d_step                [Integer]  d increment per rate_step req/min above threshold
      # @param rate_step                  [Integer]  req/min bucket size for rate escalation
      # @param unproven_d_bonus           [Integer]  extra d added for principals with 0 purchases
      # @param bad_proof_d_factor         [Integer]  d += bad_proof_count * this factor
      # @param d_min                      [Integer]  floor d when issuing any challenge
      # @param d_max                      [Integer]  ceiling d (hard cap)
      class RateAndReputation < Policy
        def initialize(
          proven_purchases_threshold: 5,
          low_rate_threshold:         10,
          base_d:                     5,
          rate_d_step:                1,
          rate_step:                  10,
          unproven_d_bonus:           2,
          bad_proof_d_factor:         3,
          d_min:                      3,
          d_max:                      14
        )
          @proven_purchases_threshold = proven_purchases_threshold
          @low_rate_threshold         = low_rate_threshold
          @base_d                     = base_d
          @rate_d_step                = rate_d_step
          @rate_step                  = rate_step
          @unproven_d_bonus           = unproven_d_bonus
          @bad_proof_d_factor         = bad_proof_d_factor
          @d_min                      = d_min
          @d_max                      = d_max
        end

        # @param identity [Object] opaque
        # @param verb     [Symbol]
        # @param factors  [Factors]
        # @return [Hash{alg:, params:}] or nil
        def challenge_for(identity:, verb:, factors:)
          purchases   = factors.settled_purchases_count.to_i
          rate        = factors.request_rate_per_min.to_i
          bad_proofs  = factors.bad_proof_count.to_i

          # Free pass: proven principal, low traffic, no bad-proof history.
          return nil if proven?(purchases) && low_rate?(rate) && bad_proofs.zero?

          d = compute_d(purchases, rate, bad_proofs)
          { alg: "argon2id", params: Backends.fetch("argon2id").params(d: d) }
        end

        private

        def proven?(purchases)
          purchases >= @proven_purchases_threshold
        end

        def low_rate?(rate)
          rate <= @low_rate_threshold
        end

        def compute_d(purchases, rate, bad_proofs)
          d = @base_d

          # High request rate: one d increment per rate_step req/min above the threshold.
          if rate > @low_rate_threshold
            excess = rate - @low_rate_threshold
            d += @rate_d_step * excess.fdiv(@rate_step).ceil
          end

          # Unproven principal (zero purchases): extra difficulty.
          d += @unproven_d_bonus if purchases.zero?

          # Bad proofs escalate fast — each invalid proof is a clear bad-faith signal.
          d += bad_proofs * @bad_proof_d_factor

          d.clamp(@d_min, @d_max)
        end
      end
    end
  end
end
