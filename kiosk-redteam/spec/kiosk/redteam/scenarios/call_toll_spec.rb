# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# An origin in memory: each account pays a proof on every 10th call of `my_rows`.
class CallTollOrigin
  EVERY = 10

  def initialize(reset_on_rotation: false)
    @counts = Hash.new(0)
    @spent = []
    @lock = Mutex.new
    @reset_on_rotation = reset_on_rotation
    @clients = 0
  end

  def register(request)
    return problem_return('pow_required', status: 402, challenges: [{}]) unless request.headers['Kiosk-Pow']

    json_return(201, 'client_id' => "agent-#{@lock.synchronize { @clients += 1 }}")
  end

  def rotate(request)
    @counts[account(request.body, 'client_assertion')] = 0 if @reset_on_rotation
    json_return(200, {})
  end

  def query(request)
    return problem_return('bad_request', status: 400) if request.uri.query.to_s.include?('redteam_unknown_argument')

    user = JWT.decode(request.headers['Authorization'].delete_prefix('DPoP '), nil, false).first['sub']
    @lock.synchronize { answer(user, request.headers['Kiosk-Pow']) }
  end

  private

  def answer(user, proof)
    return paid(user, proof) if proof

    @counts[user] += 1
    @counts[user] >= EVERY ? toll : json_return(200, [])
  end

  def paid(user, proof)
    return toll if @spent.include?(proof)

    @spent << proof
    @counts[user] = 0
    json_return(200, [])
  end

  def toll = problem_return('pow_required', status: 402, challenges: [{}])

  def account(body, field)
    "user-#{JWT.decode(JSON.parse(body)[field], nil, false).first['sub'].delete_prefix('agent-')}"
  end
end

# A person whose account the assistants it links share.
class CallTollPerson
  Linked = Data.define(:principal)

  def initialize = @linked = 0

  def links_a_newcomer
    @linked += 1
    token = JWT.encode({ sub: 'user-person', agent_id: "agent-p#{@linked}" }, nil, 'none')
    Linked.new(Kiosk::TestHelpers::Assistant::Principal.new(agent_id: "agent-p#{@linked}", user_id: 'user-person',
                                                            token:, key: OpenSSL::PKey.generate_key('ED25519')))
  end
end

RSpec.describe Kiosk::Redteam::Scenarios::CallToll do
  subject(:verdict) { described_class.new.call(client, profile) }

  let(:client) { Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL) }
  let(:origin) { CallTollOrigin.new }
  let(:person) { CallTollPerson.new }
  let(:profile) do
    Kiosk::Redteam::Profile.new(tolled_calls_per_proof: CallTollOrigin::EVERY, tolled_query: 'my_rows', person: -> { person })
  end

  before do
    # Each solve answers a new proof, as a real solver does for a new challenge.
    allow(Kiosk::TestHelpers::Wire).to receive(:solve) { [{ 'challenge' => {}, 'nonce' => SecureRandom.hex }] }
    stub_request(:post, "#{BASE_URL}/kiosk/oauth/register").to_return { origin.register(it) }
    stub_tokens
    stub_request(:post, "#{BASE_URL}/kiosk/auth/rotate").to_return { origin.rotate(it) }
    stub_request(:get, %r{\A#{BASE_URL}/kiosk/my_rows}).to_return { origin.query(it) }
  end

  it 'is blocked when every probe meets the toll on call N' do
    expect(verdict).to have_attributes(blocked: true, skipped: false, status: 402)
    expect(verdict.detail).to include('a replayed proof')
  end

  context 'when a rotated key sets the count back' do
    let(:origin) { CallTollOrigin.new(reset_on_rotation: true) }

    it 'is a breach that names the rotated key' do
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('a rotated key: call 10 with a rotated key answered HTTP 200')
    end
  end

  context 'when the origin tolls no call' do
    let(:profile) do
      Kiosk::Redteam::Profile.new(tolled_calls_per_proof: CallTollOrigin::EVERY + 100, tolled_query: 'my_rows',
                                  person: -> { person })
    end

    it 'does not pass' do
      expect(verdict.blocked).to be(false)
    end
  end

  it 'skips a profile that declares no call toll' do
    expect(described_class.new.call(client, Kiosk::Redteam::Profile.new)).to have_attributes(skipped: true)
  end
end
