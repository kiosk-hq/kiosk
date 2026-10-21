# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'

# Helpers for driving the broker over HTTP as skooti, the registered operator.
module BrokerRequests
  def callback_url = 'http://127.0.0.1:3004/kyc/callback'

  def intake_headers(secret = OperatorRegistry.registry['skooti'][:secret])
    { 'Authorization' => "Bearer #{secret}", 'Content-Type' => 'application/json' }
  end

  def intake(body, headers: intake_headers)
    post '/verifications', params: body.to_json, headers: headers
  end

  def valid_intake_body(overrides = {})
    {
      operator_id: 'skooti',
      callback_url: callback_url,
      requested_claims: %w[age_over_18 licence_a1 licence_a],
      subject_handle: 'user-uuid-123'
    }.merge(overrides)
  end

  # Opens a request and returns its request_id.
  def open_request(overrides = {})
    intake(valid_intake_body(overrides))
    response.parsed_body['request_id']
  end

  # Approves as a human who holds a licence of `licence_category`.
  def approve(request_id, licence_category: 'A')
    post '/verify', params: { request: request_id, decision: 'approve', licence_category: }.compact
  end

  # Approves with the callback stubbed. Returns what the callback received.
  def approve_capturing(request_id, **)
    delivered = {}
    CallbackPoster.stub(:deliver, ->(**args) { delivered.replace(args) && 200 }) { approve(request_id, **) }
    delivered
  end

  # Runs the block; the test fails if the block posts a callback.
  def posting_no_callback(&)
    CallbackPoster.stub(:deliver, ->(**) { flunk 'the broker posted a callback' }, &)
  end

  # The claims of a JWS that the broker's public key verifies EdDSA, and that carries exp, iss and sub.
  def decode(jws)
    header, claims, signature = jws.split('.').map { Base64.urlsafe_decode64(it) }
    key = OpenSSL::PKey.read(ProveKey.public_key)

    assert_equal({ 'alg' => 'EdDSA', 'typ' => 'JWT' }, JSON.parse(header))
    assert key.verify(nil, signature, jws.rpartition('.').first), 'the broker key does not verify the attestation'
    JSON.parse(claims).tap { |payload| assert_empty %w[exp iss sub] - payload.keys }
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) { include BrokerRequests }
