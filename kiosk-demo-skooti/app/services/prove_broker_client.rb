# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# ProveBrokerClient — skooti's server-to-server client for the KYC broker
# intake. On POST <endpoint>/request_kyc skooti calls the broker
# here (NOT the human), handing it skooti's callback_url, the claims it needs and
# the agent's user_id as the subject the claim must bind to; the broker returns a
# verification_url skooti relays to the agent's human. Authenticated by skooti's
# shared intake secret: the broker refuses arbitrary callers and callback hosts.
# The broker→operator leg lands on skooti's POST /kyc/callback.
module ProveBrokerClient
  # WHAT THIS CLIENT RAISES, AND WHY IT IS TWO NAMED CLASSES RATHER THAN A BARE
  # RuntimeError.
  #
  # Every failure here used to be `raise "…"`, so the caller could not tell one
  # from another and rescued none of them: `request_kyc` — a no-argument verb an
  # assistant can call FIRST — answered `500 action_failed` with the Ruby class
  # and message in `detail`, and in the connection-refused case with this
  # operator's own broker host and port. MEASURED on a plainly-booted origin
  # (2026-09-05): `Action "request_kyc" raised RuntimeError: KYC broker intake
  # secret is not configured …` and `Action "request_kyc" raised
  # Errno::ECONNREFUSED: Failed to open TCP connection to 127.0.0.1:9 …`.
  #
  # The split is the one the WIRE has to make, which is why it is drawn here
  # rather than by inspecting a message at the caller:
  #
  #   NotConfigured — this deployment cannot open a verification at all, and no
  #                   retry changes that. It is the same fact the engine's own
  #                   KycVerifier answers `501 module_not_served` for when no
  #                   kyc_public_key is set: the two halves of one module, and
  #                   an assistant cannot tell an operator's INTENT from outside
  #                   anyway.
  #   Unavailable   — the broker was reachable-in-principle and the request did
  #                   not complete: refused, timed out, answered something other
  #                   than 201, or answered a body without the two fields this
  #                   operator must store. Transient, so it must NOT be a 501 —
  #                   that status is cacheable by default and would tell an
  #                   assistant to stop asking.
  #
  # NotConfigured is a subclass, so a caller that only cares "no verification
  # today" rescues Unavailable and gets both.
  Unavailable   = Class.new(StandardError)
  NotConfigured = Class.new(Unavailable)

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
      # The broker stamps this as the claim's `aud`, which is what the engine's
      # KycVerifier compares against c.kyc_audience: the claim is bound to skooti.
      audience:         Kiosk.configuration.kyc_audience,
    )

    # The shared intake bearer comes from Rails custom config, set from this
    # operator's own env variable with NO shipped default anywhere — a default in
    # a public repo would let anyone impersonate this intake. A deploy that has
    # not configured it fails HERE, loudly, at the first request_kyc rather than
    # presenting a guessable token.
    secret = Rails.configuration.x.kiosk.prove_intake_secret
    if secret.to_s.empty?
      raise NotConfigured, "KYC broker intake secret is not configured — set " \
                           "KIOSK_PROVE_INTAKE_SECRET to the SAME value the broker holds for this " \
                           "operator; there is no shipped default."
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

    res = begin
      http.request(req)
    rescue ::Timeout::Error, ::SocketError, ::SystemCallError, ::IOError,
           ::OpenSSL::SSL::SSLError => e
      raise Unavailable, "KYC broker intake could not be reached (#{e.class})"
    end
    raise Unavailable, "KYC broker intake answered #{res.code}" unless res.code.to_i == 201

    intake = begin
      JSON.parse(res.body)
    rescue ::JSON::ParserError
      raise Unavailable, "KYC broker intake answered a body that is not JSON"
    end

    # THE CHECKED READ, HERE RATHER THAN AT THE CALLER. The caller stores
    # `request_id` as the row's token and relays `verification_url` to the
    # agent's human, so a response missing either is not a verification this
    # operator can hold — and a bare `fetch` for them one layer up answered that
    # with a KeyError, i.e. with a 500 carrying a Ruby message.
    unless intake.is_a?(::Hash) && !intake["request_id"].to_s.empty? &&
           !intake["verification_url"].to_s.empty?
      raise Unavailable, "KYC broker intake answered without a request_id and verification_url"
    end

    intake
  end
end
