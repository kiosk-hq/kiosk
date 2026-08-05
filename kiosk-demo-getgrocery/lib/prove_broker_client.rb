# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# ProveBrokerClient — getgrocery's server-to-server client for the prove.my
# broker intake (design §4.1 / §5.1). On `run request_kyc`, getgrocery calls the
# broker here (NOT the human) to START an age verification, handing the broker
# getgrocery's callback_url, the SINGLE claim it needs (age_over_18 — NOT a
# driving licence), and the agent's user_id as the subject the claim must bind
# to. The broker returns a verification_url getgrocery relays to the agent's
# human.
#
# Authenticated by getgrocery's shared intake secret (the broker refuses
# arbitrary callers and arbitrary callback hosts). This is the operator→broker
# leg; the broker→operator leg lands on getgrocery's POST /kyc/callback.
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
      # The operator-binding audience getgrocery declares — the value its engine
      # KycVerifier compares the minted claim's `aud` against (c.kyc_audience).
      # The broker stamps this as `aud`, so a claim minted here is bound to
      # getgrocery (a claim minted for skooti cannot unlock getgrocery).
      audience:         Kiosk.configuration.kyc_audience,
    )

    req = Net::HTTP::Post.new(
      uri,
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{ProveTrust.intake_secret}",
    )
    req.body = body

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5

    res = http.request(req)
    unless res.code.to_i == 201
      raise "prove.my intake failed (#{res.code}): #{res.body}"
    end

    JSON.parse(res.body)
  end
end
