# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# ProveBrokerClient — getgrocery's server-to-server client for the KYC broker
# intake (design §4.1 / §5.1). getgrocery calls the broker here, not the human,
# and gets back a verification_url to relay. Authenticated by the shared intake
# secret, so the broker refuses arbitrary callers and arbitrary callback hosts.
# This is the operator→broker leg; the broker→operator leg lands on
# POST /kyc/callback.
module ProveBrokerClient
  module_function

  # Start a verification at the broker.
  #
  # @param callback_url     [String] getgrocery's own POST /kyc/callback URL
  # @param requested_claims [Array<String>] e.g. ["age_over_18"]
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
      # The broker stamps this as the claim's `aud`, which the engine's
      # KycVerifier compares against c.kyc_audience — so a claim minted for
      # skooti cannot unlock getgrocery.
      audience:         Kiosk.configuration.kyc_audience,
    )

    # The shared intake bearer comes from Rails custom config (K-650), with NO
    # shipped default anywhere (K-547 — a default in a public repo would let
    # anyone impersonate this operator's intake). A deploy that has not
    # configured it fails HERE, loudly, rather than presenting a guessable token.
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
