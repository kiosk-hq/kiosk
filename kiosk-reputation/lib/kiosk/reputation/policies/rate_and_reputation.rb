# frozen_string_literal: true

module Kiosk
  module Reputation
    module Policies
      # Example policy, meant to be replaced: free for a proven, low-rate principal
      # with no bad proofs; otherwise a number of independent equihash proofs that
      # grows with request rate, no purchases and past bad proofs.
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
          # Kiosk::Pow::Equihash defaults as literals, so this gem loads without it.
          equihash_n:                 168,
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

          if rate > @low_rate_threshold
            excess = rate - @low_rate_threshold
            count += @rate_count_step * excess.fdiv(@rate_step).ceil
          end

          count += @unproven_count_bonus if purchases.zero?

          count += bad_proofs * @bad_proof_count_factor

          count.clamp(@count_min, @count_max)
        end
      end
    end
  end
end
