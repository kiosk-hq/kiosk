# frozen_string_literal: true

module Kiosk
  module Reputation
    module Policies
      # EXAMPLE policy — providers are expected to REPLACE this wholesale.
      #
      # This is the shipped illustrative policy for the "scrape-vs-buy" pattern
      # on a read-heavy endpoint. Its thresholds and count-curve are opinionated
      # defaults; tune them or write a domain-specific subclass instead.
      #
      # == Difficulty via N×PoW (equihash)
      #
      # Equihash has no continuous difficulty dial (memory is fixed by (n,k)).
      # The anti-abuse lever is PROOF COUNT: a normal client solves 1 proof, a
      # suspicious one a handful, an abuser ~10 — each an INDEPENDENT challenge
      # (distinct salt, no amortisation). This policy therefore returns a
      # `count`, which the gate turns into that many challenges.
      #
      # == Logic
      #
      # Serve without challenge when ALL of:
      #   - settled_purchases_count >= proven_purchases_threshold (principal has paid)
      #   - request_rate_per_min   <= low_rate_threshold          (not flooding)
      #   - bad_proof_count        == 0                          (no bad-faith history)
      #
      # Otherwise demand `count` equihash proofs, where `count` is:
      #
      #   count = base_count
      #     + ceil((rate - low_rate_threshold) / rate_step) * rate_count_step [if rate > threshold]
      #     + unproven_count_bonus                                            [if 0 purchases]
      #     + bad_proof_count * bad_proof_count_factor                        [bad-faith escalation]
      #   count = count.clamp(count_min, count_max)
      #
      # The `bad_proof_count_factor` is intentionally high so that a few invalid
      # proofs push a principal into a hard tier quickly. An honest client solver
      # never submits a wrong proof.
      #
      # == Constructor params (all have sane defaults)
      # @param proven_purchases_threshold [Integer]  min settled purchases to be "proven"
      # @param low_rate_threshold         [Integer]  max req/min considered low-rate
      # @param base_count                 [Integer]  proofs demanded when challenging at all
      # @param rate_count_step            [Integer]  proof increment per rate_step req/min above threshold
      # @param rate_step                  [Integer]  req/min bucket size for rate escalation
      # @param unproven_count_bonus       [Integer]  extra proofs for principals with 0 purchases
      # @param bad_proof_count_factor     [Integer]  count += bad_proof_count * this factor
      # @param count_min                  [Integer]  floor proofs when issuing any challenge
      # @param count_max                  [Integer]  ceiling proofs (hard cap)
      # @param equihash_n                 [Integer]  equihash n parameter (solver memory)
      # @param equihash_k                 [Integer]  equihash k parameter (tree depth)
      class RateAndReputation < Policy
        def initialize(
          proven_purchases_threshold: 5,
          low_rate_threshold:         10,
          base_count:                 1,
          rate_count_step:            1,
          rate_step:                  10,
          unproven_count_bonus:       1,
          bad_proof_count_factor:     3,
          count_min:                  1,
          count_max:                  10,
          equihash_n:                 192,
          equihash_k:                 7
        )
          @proven_purchases_threshold = proven_purchases_threshold
          @low_rate_threshold         = low_rate_threshold
          @base_count                 = base_count
          @rate_count_step            = rate_count_step
          @rate_step                  = rate_step
          @unproven_count_bonus       = unproven_count_bonus
          @bad_proof_count_factor     = bad_proof_count_factor
          @count_min                  = count_min
          @count_max                  = count_max
          @equihash_params            = { n: equihash_n, k: equihash_k }
        end

        # @param identity [Object] opaque
        # @param verb     [Symbol]
        # @param factors  [Factors]
        # @return [Hash{alg:, params:, count:}] or nil
        def challenge_for(identity:, verb:, factors:)
          purchases   = factors.settled_purchases_count.to_i
          rate        = factors.request_rate_per_min.to_i
          bad_proofs  = factors.bad_proof_count.to_i

          # Free pass: proven principal, low traffic, no bad-proof history.
          return nil if proven?(purchases) && low_rate?(rate) && bad_proofs.zero?

          {
            alg:    "equihash",
            params: @equihash_params,
            count:  compute_count(purchases, rate, bad_proofs),
          }
        end

        private

        def proven?(purchases)
          purchases >= @proven_purchases_threshold
        end

        def low_rate?(rate)
          rate <= @low_rate_threshold
        end

        def compute_count(purchases, rate, bad_proofs)
          count = @base_count

          # High request rate: one proof increment per rate_step req/min above the threshold.
          if rate > @low_rate_threshold
            excess = rate - @low_rate_threshold
            count += @rate_count_step * excess.fdiv(@rate_step).ceil
          end

          # Unproven principal (zero purchases): extra proofs.
          count += @unproven_count_bonus if purchases.zero?

          # Bad proofs escalate fast — each invalid proof is a clear bad-faith signal.
          count += bad_proofs * @bad_proof_count_factor

          count.clamp(@count_min, @count_max)
        end
      end
    end
  end
end
