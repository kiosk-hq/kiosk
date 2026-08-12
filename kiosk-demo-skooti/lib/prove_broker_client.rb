# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# ProveBrokerClient — skooti's server-to-server client for the KYC broker
# intake (design §4.1 / §5.1). On `run request_kyc`, skooti calls the broker
# here (NOT the human) to START a verification, handing the broker skooti's
# callback_url, the claims it needs, and the agent's user_id as the subject the
# claim must bind to. The broker returns a verification_url skooti relays to the
# agent's human.
#
# Authenticated by skooti's shared intake secret (the broker refuses arbitrary
# callers and arbitrary callback hosts). This is the operator→broker leg; the
# broker→operator leg lands on skooti's POST /kyc/callback.
module ProveBrokerClient
  module_function

  # Start a verification at the broker.
  #
  # @param callback_url     [String] skooti's own POST /kyc/callback URL
  # @param requested_claims [Array<String>] e.g. ["age_over_18","licence_category:A"]
  # @param subject_handle   [String] the agent's user_id the claim must bind to
  # @return [Hash] { "request_id" =>, "verification_url" =>, ... } on success
  # @raise [RuntimeError] on a non-201 response or transport error
  def start_verification(callback_url:, requested_claims:, subject_handle:)
    uri  = URI.parse("#{ProveTrust.broker_url.chomp('/')}/verifications")
    body = JSON.generate(
      operator_id:      ProveTrust.operator_id,
      callback_url:     callback_url,
      requested_claims: requested_claims,
      subject_handle:   subject_handle,
      # The operator-binding audience skooti declares — the value its engine
      # KycVerifier compares the minted claim's `aud` against (c.kyc_audience).
      # The broker stamps this as `aud`, so a claim minted here is bound to skooti.
      audience:         Kiosk.configuration.kyc_audience,
    )

    # The shared intake bearer comes from Rails custom config (K-650): set in
    # config/environments/*.rb from this operator's own env variable, with NO
    # shipped default anywhere (K-547 — a default in a public repo would let
    # anyone impersonate the operator's intake). The harness pins it on both
    # sides; a deploy that has not configured it fails HERE, loudly, at the
    # first request_kyc rather than presenting a guessable token.
    secret = Rails.configuration.x.kiosk.prove_intake_secret
    if secret.to_s.empty?
      raise "KYC broker intake secret is not configured — set KIOSK_PROVE_INTAKE_SECRET to the SAME " \
            "value the broker holds for this operator; there is no shipped default (K-547/K-650/K-694)."
    end

    req = Net::HTTP::Post.new(
      uri,
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{secret}",
    )
    req.body = body

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5

    res = http.request(req)
    unless res.code.to_i == 201
      raise "KYC broker intake failed (#{res.code}): #{res.body}"
    end

    JSON.parse(res.body)
  end
end
