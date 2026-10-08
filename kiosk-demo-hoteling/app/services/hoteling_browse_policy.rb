# frozen_string_literal: true

# Browsing is priced by request rate: the first few queries are free, then each
# extra costs escalating proofs. A hold (`:run`, the write kind this hook
# receives for an action) costs a flat proof; `:pay` is not tolled.
class HotelingBrowsePolicy < Kiosk::Reputation::Policy
  FREE_BROWSES = 3
  RATE_STEP    = 2
  MAX_PROOFS   = 5
  WRITE_PROOFS = 1

  def initialize(params)
    @params = params
  end

  def challenge_for(identity:, verb:, factors:)
    return { alg: Kiosk::Pow::Equihash::NAME, params: @params, count: WRITE_PROOFS } if verb == :run
    return nil unless verb == :query

    rate = factors.request_rate_per_min.to_i
    return nil if rate <= FREE_BROWSES

    count = [(rate - FREE_BROWSES + RATE_STEP - 1) / RATE_STEP, MAX_PROOFS].min
    { alg: Kiosk::Pow::Equihash::NAME, params: @params, count: count }
  end
end
