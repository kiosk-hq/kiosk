# frozen_string_literal: true

require "base64"
require "kiosk/user_identity_providers/devise"
require "kiosk/pow/equihash"
require "kiosk/reputation"

Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

EQUIHASH_PARAMS = { n: 168, k: 7 }.freeze
ATABLEFOR_BACKOFF_FREE_CALLS = 3

ATABLEFOR_POW_MODE = ENV.fetch("KIOSK_POW_MODE") { Rails.env.local? ? "off" : "reputation" }.to_sym
unless %i[off demo reputation backoff].include?(ATABLEFOR_POW_MODE)
  raise "KIOSK_POW_MODE=#{ATABLEFOR_POW_MODE} is invalid — use one of: off, demo, reputation, backoff."
end

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id
  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.issuer            = ENV.fetch("KIOSK_ISSUER")
  c.signing_key       = Base64.decode64(ENV.fetch("KIOSK_SIGNING_KEY_B64"))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = {
    name:           "atablefor",
    support:        "demo@kiosk.tech",
    pow_difficulty: "high",
    pow_notice:     "beware: memory- and CPU-intensive proof-of-work — this provider prices " \
                    "registration/browsing with Equihash n=168 k=7 (~1.3 GiB per proof; ~10 s on " \
                    "a reference numpy solver, measured on one M-series laptop core). This is " \
                    "deliberate: the toll is the DoS shield, and it costs the client, not the " \
                    "provider. Solve it with the solver the Kiosk skill pins.",
  }
  c.skill_url    = "https://kiosk.tech/skill-v0.5.12.md"
  c.skill_sha256 = "cf83b63682cd12ca042a18cae871bef0c2f531b98e068c5b15b38f6973e45756"

  c.validate_requests  = true
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = "/users/sign_in"

  c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET")
  c.pow_ttl                 = 300
  c.registration_pow_count  = 1
  c.registration_pow_params = EQUIHASH_PARAMS

  case ATABLEFOR_POW_MODE
  when :demo
    c.reputation_policy  = AtableforDemoPowPolicy.new(Kiosk::Pow::Equihash.params(**EQUIHASH_PARAMS))
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
  when :reputation
    # 0 confirmed bookings: 2 proofs · 1: 1 proof · 2+: free.
    c.reputation_policy = Kiosk::Reputation::Policies::RateAndReputation.new(
      proven_purchases_threshold: 2,
      low_rate_threshold:         100,
      base_count:                 1,
      count_min:                  1,
      count_max:                  10,
      rate_count_step:            1,
      rate_step:                  10,
      unproven_count_bonus:       1,
      bad_proof_count_factor:     3,
      equihash_n:                 EQUIHASH_PARAMS[:n],
      equihash_k:                 EQUIHASH_PARAMS[:k],
    )
    # The gate runs before the session context is set, so `Booking.own` cannot be used here.
    c.reputation_factors = ->(identity:, **) {
      Kiosk::Reputation::Factors.new(
        kyc_level:               nil,
        settled_purchases_count: Booking.confirmed.where(user_id: identity.user_id).count,
        settled_purchases_cents: nil,
        request_rate_per_min:    0,
        account_age_seconds:     nil,
        dispute_count:           nil,
        bad_proof_count:         0,
      )
    }
  when :backoff
    c.reputation_policy = Kiosk::Reputation::Policies::Backoff.new(
      count: ATABLEFOR_BACKOFF_FREE_CALLS,
      base:  { alg: Kiosk::Pow::Equihash::NAME, params: Kiosk::Pow::Equihash.params(**EQUIHASH_PARAMS), count: 1 },
    )
    c.reputation_factors = ->(**) { Kiosk::Reputation::Factors.empty }
  end
end
