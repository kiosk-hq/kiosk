# frozen_string_literal: true

require 'spec_helper'

# The broker's security model over HTTP: intake auth and allow-list, the
# unguessable capability, single use, TTL, the signed anonymized claim bound to
# one request, operator and subject, and the callback allow-list.
RSpec.describe 'KYC broker: POST /verifications (intake)', type: :request do
  it 'creates a pending request and returns a verification_url carrying the token' do
    intake(valid_intake_body)
    expect(response).to have_http_status(:created)
    json = JSON.parse(response.body)
    expect(json['status']).to eq('pending')
    expect(json['request_id']).to be_present
    expect(json['verification_url']).to include("/verify?request=#{json['request_id']}")
    # The operator gets the nonce at intake. The human page does not show it.
    expect(json['nonce']).to be_present

    row = ProveRequest.find(json['request_id'])
    expect(json['nonce']).to eq(row.nonce)
    expect(row.operator_id).to eq('skooti')
    expect(row.subject_handle).to eq('user-uuid-123')
    expect(row.status).to eq('pending')
    expect(row.nonce).to be_present
    expect(row.expires_at).to be > Time.current
  end
end

RSpec.describe 'KYC broker: intake refusals', type: :request do
  it 'rejects an unknown operator / bad secret (401) — a stranger cannot open requests' do
    intake(valid_intake_body, headers: intake_headers('wrong'))
    expect(response).to have_http_status(:unauthorized)
    expect(ProveRequest.count).to eq(0)
  end

  it 'rejects a callback_url whose host is NOT allow-listed (SSRF/open-relay guard, 403)' do
    intake(valid_intake_body(callback_url: 'http://evil.example.com/steal'))
    expect(response).to have_http_status(:forbidden)
    expect(ProveRequest.count).to eq(0)
  end

  it 'rejects unknown/empty requested_claims (400)' do
    intake(valid_intake_body(requested_claims: ['not_a_claim']))
    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects a missing subject_handle (400)' do
    intake(valid_intake_body(subject_handle: ''))
    expect(response).to have_http_status(:bad_request)
  end
end

RSpec.describe 'KYC broker: intake audience', type: :request do
  # getgrocery authenticates with its own secret but asks for skooti's audience.
  # The broker takes `aud` from getgrocery's registration and refuses the body's value.
  it "rejects an operator requesting ANOTHER operator's audience (cross-operator forgery)" do
    intake(
      {
        operator_id: 'getgrocery',
        callback_url: 'http://127.0.0.1/kyc/callback',
        requested_claims: ['age_over_18'],
        subject_handle: 'victim-subject',
        audience: 'skooti'
      },
      headers: intake_headers(OperatorRegistry.registry['getgrocery'][:secret])
    )
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)['error']).to match(/audience/)
    expect(ProveRequest.count).to eq(0)
  end
end

RSpec.describe 'KYC broker: GET /verify (human page)', type: :request do
  it 'shows the yes/no questions for a live request' do
    rid = open_request
    get '/verify', params: { request: rid }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('over 18')
    expect(response.body).to include('category A')
  end

  it 'does not reveal anything for an unknown token' do
    get '/verify', params: { request: 'not-a-real-token' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('not recognised')
  end
end

RSpec.describe 'KYC broker: POST /verify approve (the signed claim)', type: :request do
  it 'mints a signed claim bound to (subject + operator + request) and echoes the nonce' do
    rid = open_request
    row = ProveRequest.find(rid)
    delivered = capture_delivery
    approve(rid)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Confirmed')

    payload = decode(delivered[:kyc_jws])
    expect(payload['sub']).to eq(row.subject_handle)
    expect(payload['iss']).to eq(ProveKey.issuer)
    expect(payload['level']).to eq('verified')
    expect(payload['operator']).to eq('skooti')
    expect(payload['aud']).to eq('skooti')
    expect(payload['request_id']).to eq(rid)
    expect(payload['nonce']).to eq(row.nonce)
    expect(payload['attributes']).to eq({ 'age_over_18' => true, 'licence_a' => true })

    expect(delivered[:nonce]).to eq(row.nonce)
    expect(delivered[:callback_url]).to eq(callback_url)
    expect(row.reload.status).to eq('confirmed')
  end
end

RSpec.describe 'KYC broker: POST /verify approve (the audience)', type: :request do
  # The broker checks a declared audience against the registration and stamps
  # the registered one, which the operator's KycVerifier compares against.
  it "binds aud to the operator's REGISTERED audience, accepting a matching body declaration" do
    rid = open_request(audience: 'skooti')
    expect(ProveRequest.find(rid).audience).to eq('skooti')
    delivered = capture_delivery
    approve(rid)

    payload = decode(delivered[:kyc_jws])
    expect(payload['aud']).to eq('skooti')
    # The operator handle stays a separate claim, for the callback.
    expect(payload['operator']).to eq('skooti')
  end

  it 'mints aud from the registration even when the body declares no audience (aud == operator_id)' do
    rid = open_request
    # The row records the registered audience, never a raw body value.
    expect(ProveRequest.find(rid).audience).to eq('skooti')
    delivered = capture_delivery
    approve(rid)
    expect(decode(delivered[:kyc_jws])['aud']).to eq('skooti')
  end
end

RSpec.describe 'KYC broker: POST /verify approve (lifetime and attributes)', type: :request do
  it 'mints an attestation valid for one year' do
    rid = open_request
    delivered = capture_delivery
    approve(rid)
    payload = decode(delivered[:kyc_jws])
    expect(payload['exp'] - payload['iat']).to eq(365 * 24 * 3600)
  end

  it 'grants ONLY the attributes the operator asked for (age_over_18 alone)' do
    rid = open_request(requested_claims: ['age_over_18'])
    delivered = capture_delivery
    approve(rid)
    payload = decode(delivered[:kyc_jws])
    expect(payload['attributes']).to eq({ 'age_over_18' => true })
  end
end

RSpec.describe 'KYC broker: POST /verify single use', type: :request do
  it 'is single-use: a second approve on a confirmed request is rejected (no re-mint)' do
    rid = open_request
    allow(CallbackPoster).to receive(:deliver).and_return(200)
    approve(rid)
    expect(ProveRequest.find(rid).status).to eq('confirmed')

    expect(CallbackPoster).not_to receive(:deliver)
    approve(rid)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'is un-confirmable once past its TTL' do
    rid = open_request
    ProveRequest.find(rid).update!(expires_at: 1.hour.ago)
    expect(CallbackPoster).not_to receive(:deliver)
    approve(rid)
    expect(response).to have_http_status(:unprocessable_entity)
  end
end

RSpec.describe 'KYC broker: POST /verify decline', type: :request do
  it 'records a decline without minting' do
    rid = open_request
    expect(CallbackPoster).not_to receive(:deliver)
    post '/verify', params: { request: rid, decision: 'decline' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Declined')
    expect(ProveRequest.find(rid).status).to eq('declined')
  end
end

# Real threads on separate connections race one committed row, so Postgres,
# not an in-process mock, decides which claim wins. Every reader is held
# between its read and its claim, so all of them see the row as pending and
# the refusals come from the conditional UPDATE, not from the pre-check.
RSpec.describe 'KYC broker: POST /verify under concurrency', type: :request do
  # `:real_concurrency` commits the row (see spec_helper.rb), so the example deletes it.
  it 'is single-use under concurrency: N racing approvals mint exactly once', :real_concurrency do
    racers = 6
    rid = open_request
    reads = hold_every_read
    slow_down_mint
    deliveries = capture_deliveries
    warm_up_routes
    statuses = race_approvals(rid, racers)

    expect(reads.count('pending')).to eq(racers)
    expect(statuses.count(200)).to eq(1)
    expect(statuses.count(422)).to eq(racers - 1)
    expect(deliveries.size).to eq(1) # exactly one mint+deliver from N racing approvals
    expect(ProveRequest.find(rid).status).to eq('confirmed')
  ensure
    ProveRequest.delete(rid)
  end
end

RSpec.describe 'KYC broker: GET /prove_key.pem', type: :request do
  it 'serves the ProveKey public PEM operators pin' do
    get '/prove_key.pem'
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('PUBLIC KEY')
  end
end
