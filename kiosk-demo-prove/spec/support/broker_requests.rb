# frozen_string_literal: true

require 'jwt'
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
      requested_claims: ['age_over_18', 'licence_category:A'],
      subject_handle: 'user-uuid-123'
    }.merge(overrides)
  end

  # Opens a request and returns its request_id.
  def open_request(overrides = {})
    intake(valid_intake_body(overrides))
    JSON.parse(response.body)['request_id']
  end

  # Stubs the callback and returns the hash its last call receives.
  def capture_delivery
    delivered = {}
    allow(CallbackPoster).to receive(:deliver) do |args|
      delivered.replace(args)
      200
    end
    delivered
  end

  def approve(request_id)
    post '/verify', params: { request: request_id, decision: 'approve' }
  end

  def decode(jws)
    key = OpenSSL::PKey::RSA.new(ProveKey.public_key)
    JWT.decode(jws, key, true, algorithms: ['RS256'], required_claims: %w[exp iss sub]).first
  end
end

RSpec.configure { |config| config.include BrokerRequests, type: :request }
