# frozen_string_literal: true

require 'test_helper'

# The broker's security model over HTTP: intake auth and allow-list, the
# unguessable capability, single use, TTL, the signed anonymized claim bound to
# one request, operator and subject, and the callback allow-list.
class IntakeTest < ActionDispatch::IntegrationTest
  test 'creates a pending request and returns a verification_url carrying the token' do
    intake(valid_intake_body)
    json = response.parsed_body
    row = ProveRequest.find(json['request_id'])

    assert_response :created
    # The operator gets the nonce at intake. The human page does not show it.
    assert_equal({ 'status' => 'pending', 'nonce' => row.nonce, 'expires_at' => row.expires_at.utc.iso8601,
                   'verification_url' => "http://www.example.com/verify?request=#{row.request_id}" },
                 json.slice('status', 'nonce', 'expires_at', 'verification_url'))
    assert_equal ['skooti', 'user-uuid-123', 'pending', true, true],
                 [row.operator_id, row.subject_handle, row.status, row.nonce.present?, row.expires_at.future?]
  end

  test 'rejects an unknown operator / bad secret (401) — a stranger cannot open requests' do
    intake(valid_intake_body, headers: intake_headers('wrong'))

    assert_response :unauthorized
    assert_equal 0, ProveRequest.count
  end

  test 'rejects a callback_url whose host is NOT allow-listed (SSRF/open-relay guard, 403)' do
    intake(valid_intake_body(callback_url: 'http://evil.example.com/steal'))

    assert_response :forbidden
    assert_equal 0, ProveRequest.count
  end

  test 'rejects unknown/empty requested_claims (400)' do
    intake(valid_intake_body(requested_claims: ['not_a_claim']))

    assert_response :bad_request
  end

  test 'rejects a missing subject_handle (400)' do
    intake(valid_intake_body(subject_handle: ''))

    assert_response :bad_request
  end

  test 'rejects a body that is not JSON (400)' do
    post '/verifications', params: '{"operator_id":', headers: intake_headers

    assert_response :bad_request
    assert_equal 0, ProveRequest.count
  end

  # getgrocery authenticates with its own secret but asks for skooti's audience.
  # The broker takes `aud` from getgrocery's registration and refuses the body's value.
  test "rejects an operator requesting ANOTHER operator's audience (cross-operator forgery)" do
    intake({ operator_id: 'getgrocery', callback_url: 'http://127.0.0.1/kyc/callback',
             requested_claims: ['age_over_18'], subject_handle: 'victim-subject', audience: 'skooti' },
           headers: intake_headers(OperatorRegistry.registry['getgrocery'][:secret]))

    assert_response :forbidden
    assert_match(/audience/, response.parsed_body['error'])
    assert_equal 0, ProveRequest.count
  end
end

class VerificationPageTest < ActionDispatch::IntegrationTest
  test 'shows the yes/no questions for a live request' do
    get '/verify', params: { request: open_request }

    assert_response :ok
    assert_includes response.body, 'over 18'
    assert_includes response.body, 'category A'
  end

  test 'does not reveal anything for an unknown token' do
    get '/verify', params: { request: 'not-a-real-token' }

    assert_response :ok
    assert_includes response.body, 'not recognised'
  end
end

class ApprovalTest < ActionDispatch::IntegrationTest
  test 'mints a signed claim bound to (subject + operator + request) and echoes the nonce' do
    rid = open_request
    row = ProveRequest.find(rid)
    delivered = approve_capturing(rid)
    payload = decode(delivered[:kyc_jws])

    assert_response :ok
    assert_includes response.body, 'Confirmed'
    assert_equal [{ 'sub' => row.subject_handle, 'iss' => ProveKey.issuer, 'level' => 'verified',
                    'operator' => 'skooti', 'aud' => 'skooti', 'request_id' => rid, 'nonce' => row.nonce,
                    'attributes' => { 'age_over_18' => true, 'licence_a' => true } },
                  row.nonce, callback_url, 'confirmed'],
                 [payload.slice('sub', 'iss', 'level', 'operator', 'aud', 'request_id', 'nonce', 'attributes'),
                  *delivered.values_at(:nonce, :callback_url), row.reload.status]
  end

  # The broker checks a declared audience against the registration and stamps
  # the registered one, which the operator's KycVerifier compares against.
  test "binds aud to the operator's REGISTERED audience, accepting a matching body declaration" do
    rid = open_request(audience: 'skooti')

    assert_equal 'skooti', ProveRequest.find(rid).audience
    payload = decode(approve_capturing(rid)[:kyc_jws])
    # The operator handle stays a separate claim, for the callback.
    assert_equal %w[skooti skooti], payload.values_at('aud', 'operator')
  end

  test 'mints aud from the registration even when the body declares no audience (aud == operator_id)' do
    rid = open_request
    # The row records the registered audience, never a raw body value.
    assert_equal 'skooti', ProveRequest.find(rid).audience
    assert_equal 'skooti', decode(approve_capturing(rid)[:kyc_jws])['aud']
  end

  test 'mints an attestation valid for one year' do
    payload = decode(approve_capturing(open_request)[:kyc_jws])

    assert_equal 365 * 24 * 3600, payload['exp'] - payload['iat']
  end

  test 'grants ONLY the attributes the operator asked for (age_over_18 alone)' do
    payload = decode(approve_capturing(open_request(requested_claims: ['age_over_18']))[:kyc_jws])

    assert_equal({ 'age_over_18' => true }, payload['attributes'])
  end

  test 'is single-use: a second approve on a confirmed request is rejected (no re-mint)' do
    rid = open_request
    approve_capturing(rid)

    assert_equal 'confirmed', ProveRequest.find(rid).status

    posting_no_callback { approve(rid) }

    assert_response :unprocessable_content
  end

  test 'is un-confirmable once past its TTL' do
    rid = open_request
    ProveRequest.find(rid).update!(expires_at: 1.hour.ago)
    posting_no_callback { approve(rid) }

    assert_response :unprocessable_content
  end

  test 'records a decline without minting' do
    rid = open_request
    posting_no_callback { post '/verify', params: { request: rid, decision: 'decline' } }

    assert_response :ok
    assert_includes response.body, 'Declined'
    assert_equal 'declined', ProveRequest.find(rid).status
  end
end

# Real threads on separate connections race one committed row, so Postgres,
# not an in-process mock, decides which claim wins. Every reader is held
# between its read and its claim, so all of them see the row as pending and
# the refusals come from the conditional UPDATE, not from the pre-check.
class ConcurrentApprovalTest < ActionDispatch::IntegrationTest
  include ApprovalRace

  # The other threads read the row on their own connections, so it is committed; the test deletes it.
  self.use_transactional_tests = false

  test 'is single-use under concurrency: N racing approvals mint exactly once' do
    racers = 6
    rid = open_request
    statuses, reads, deliveries = race_approvals(rid, racers)

    # Every reader saw the row pending; one approval won, minted once, and confirmed it.
    assert_equal racers, reads.count('pending')
    assert_equal [1, racers - 1, 1, 'confirmed'],
                 [statuses.count(200), statuses.count(422), deliveries.size, ProveRequest.find(rid).status]
  ensure
    ProveRequest.delete(rid)
  end
end

class ProveKeyTest < ActionDispatch::IntegrationTest
  test 'serves the ProveKey public PEM operators pin' do
    get '/prove_key.pem'

    assert_response :ok
    assert_includes response.body, 'PUBLIC KEY'
  end
end

class CallbackAllowListTest < ActiveSupport::TestCase
  OPERATOR = { callback_host: 'shop.example' }.freeze

  test 'posts to the registered host over https' do
    assert OperatorRegistry.callback_allowed?(OPERATOR, 'https://shop.example/kiosk/kyc/callback')
  end

  test 'refuses plain http to a host other than the machine itself' do
    assert_not OperatorRegistry.callback_allowed?(OPERATOR, 'http://shop.example/kiosk/kyc/callback')
  end

  test 'accepts plain http to a loopback host, for development and test' do
    assert OperatorRegistry.callback_allowed?({ callback_host: '127.0.0.1' }, 'http://127.0.0.1:3004/kyc/callback')
  end
end
