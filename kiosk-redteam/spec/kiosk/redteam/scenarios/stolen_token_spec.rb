# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe Kiosk::Redteam::Scenarios::StolenToken do
  subject(:scenario) { described_class.new }

  let(:client)  { Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL) }
  let(:profile) { Kiosk::Redteam::Profile.new(per_user_query: 'ping') }

  # The keys the scenario generates, in order: the victim's first.
  let(:generated) { [] }

  # The origin under test: 200 only to the registered key's own DPoP proof.
  def stub_origin(accept_stolen: false)
    stub_registers('a')
    stub_request(:get, verb_url('ping')).to_return do |req|
      own_call?(req) || (accept_stolen && req.headers['Authorization']) ? wire_return(status: 200, body: []) : problem_return('unauthenticated')
    end
  end

  # The victim's token with a proof that the victim's own key signs.
  def own_call?(req)
    req.headers['Authorization'] == "DPoP #{token_for('a')}" && proof_key(req.headers['Dpop']) == generated.first
  end

  def proof_key(proof)
    return nil if proof.nil?

    _, header = JWT.decode(proof, nil, false)
    Kiosk::TestHelpers::Dpop.thumbprint(JWT::JWK.import(header['jwk']).public_key)
  end

  before do
    allow(OpenSSL::PKey::RSA).to receive(:generate).and_wrap_original do |original, *args|
      original.call(*args).tap { generated << Kiosk::TestHelpers::Dpop.thumbprint(it) }
    end
  end

  it 'is blocked when the token works only with its own key' do
    stub_origin

    expect(scenario.call(client, profile)).to have_attributes(blocked: true, status: 401)
  end

  it 'is a breach when a stolen token is accepted' do
    stub_origin(accept_stolen: true)

    verdict = scenario.call(client, profile)

    expect(verdict).to have_attributes(blocked: false, status: 200)
    expect(verdict.detail).to include('as a bearer token')
  end

  it 'is a breach, not a block, when the origin refuses the control too' do
    stub_registers('a')
    stub_query('ping', status: 401, code: 'unauthenticated')

    expect(scenario.call(client, profile)).to have_attributes(blocked: false, status: 401)
  end

  it 'skips a profile that declares no routed verb' do
    expect(scenario.call(client, Kiosk::Redteam::Profile.new)).to have_attributes(skipped: true)
  end
end
