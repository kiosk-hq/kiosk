# frozen_string_literal: true

# Every query costs one Equihash proof; actions and pay are free.
class CatalogTollPolicy < Kiosk::Reputation::Policy
  def initialize(params)
    @params = params
  end

  def challenge_for(identity:, verb:, factors:)
    { alg: Kiosk::Pow::Equihash::NAME, params: @params } if verb == :query
  end
end
