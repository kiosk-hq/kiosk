# frozen_string_literal: true

# Tolls every query and lets actions through: the flat policy `rake check:pow` exercises.
class AtableforDemoPowPolicy < Kiosk::Reputation::Policy
  def initialize(pow_params)
    @pow_params = pow_params
  end

  def challenge_for(identity:, verb:, factors:)
    return nil unless verb == :query

    { alg: Kiosk::Pow::Equihash::NAME, params: @pow_params }
  end
end
