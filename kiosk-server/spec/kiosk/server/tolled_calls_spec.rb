# frozen_string_literal: true

require 'securerandom'
require 'kiosk/pow/equihash'
require 'kiosk/reputation'
require_relative '../../support/postgres'

# A backend that accepts the nonce 'solved', so a proof costs the spec no work.
module AcceptingEquihash
  def self.verify(nonce:, **) = nonce == 'solved' # rubocop:disable Naming/PredicateMethod -- `verify` is the backend contract Backends.register names
end

# The toll by call count through the real gate, `RecentSpend` and the shipped
# tables: every Nth tolled call of an account answers 402 until a proof clears
# it, and the assistants bound to one account share the count and the spend.
RSpec.describe Kiosk::Server::TolledCalls do
  include_context 'with registered clients'

  let(:conn)  { ActiveRecord::Base.connection }
  let(:human) { holder! }
  let(:key)   { OpenSSL::PKey.generate_key('ED25519') }
  let(:agent) { assistant_of(human, key:) }

  before do
    schema = OauthClients::SCHEMA
    conn.execute(%(TRUNCATE "#{schema}".kiosk_checkout_mandates, "#{schema}".kiosk_visits CASCADE))
    Kiosk::Reputation::Backends.register('equihash', AcceptingEquihash)
    Kiosk.configure do |c|
      c.pow_secret        = 'tolled-calls-spec-secret-of-32-bytes'
      c.reputation_policy = Kiosk::Reputation::Policies::RecentSpend.new(within: 7 * 86_400, cap: 100)
    end
  end

  after { Kiosk::Reputation::Backends.reset! }

  # A registered assistant, bound to `account`; its client.
  def assistant_of(account, key: OpenSSL::PKey.generate_key('ED25519'))
    Kiosk::Server::AccountBinding.bind!(agent_id: register_client(key).id, user_id: account)
  end

  # An access token of `client`; `jti` names the token.
  def token(client = agent, jti = 'token-1')
    build_identity(user_id: client.user_id, agent_id: client.id, claims: { jti:, exp: Time.now.to_i + 3600 })
  end

  def call(identity = token, pow: nil)
    Kiosk::Server::PowGate.gate(identity: identity, command: 'query', verb: 'menu', body: {}, pow: pow)
  rescue Kiosk::Server::Errors::PowRequired => e
    e
  end

  def tolled?(answer) = answer.is_a?(Kiosk::Server::Errors::PowRequired)

  def calls_since_proof
    conn.select_value(%(SELECT calls_since_proof FROM "#{OauthClients::SCHEMA}".kiosk_tolled_calls WHERE user_id = '#{human}'))
  end

  # The first call that answers 402, among the next 100.
  def first_tolled_call(identity = token) = (1..100).find { tolled?(call(identity)) }

  def pay(refusal, identity = token) = call(identity, pow: [{ challenge: refusal.challenges.first, nonce: 'solved' }])

  def visit(cents, at: Time.current, account: human)
    conn.exec_query(%(INSERT INTO "#{OauthClients::SCHEMA}".kiosk_visits (user_id, value_cents, visited_at) VALUES ($1, $2, $3)), 'spec', [account, cents, at])
  end

  it 'answers 402 on the 10th call of an account with no spend, and the solved proof lets that call through' do
    expect(first_tolled_call).to eq(10)
    expect(pay(call)).to eq(:proceed)
  end

  it 'counts a 402 and its tolled retry as one call: the tolled retry sets the count to zero' do
    refusal = Array.new(10) { call }.last

    expect([tolled?(refusal), pay(refusal), calls_since_proof]).to eq([true, :proceed, 0])
  end

  it 'starts a new count of 10 after the solved proof' do
    first_tolled_call
    pay(call)

    expect(first_tolled_call).to eq(10)
  end

  it 'keeps the count when the assistant gets a new access token' do
    5.times { call(token(agent, 'token-1')) }

    expect(first_tolled_call(token(agent, 'token-2'))).to eq(5)
  end

  it 'keeps the count when the assistant rotates its key' do
    5.times { call }
    new_key = OpenSSL::PKey.generate_key('ED25519')
    jwks = jwks_of(new_key)
    thumbprint = Kiosk::Server::AssistantKey.thumbprint(Kiosk::Server::AssistantKey.from_jwks(jwks))
    rotated = Kiosk::Server::AgentRotation.call(
      type: Kiosk::Server::ClientAssertion::TYPE, jwks:,
      assertion: client_assertion(agent.id, key:, new_key: thumbprint),
      new_assertion: client_assertion(agent.id, key: new_key)
    )

    expect(first_tolled_call(token(rotated, 'token-2'))).to eq(5)
  end

  it 'answers 402 on the 20th call at half the cap of recent spend, and on none at the cap' do
    visit(50_00)
    expect(first_tolled_call).to eq(20)

    visit(50_00)
    expect(first_tolled_call).to be_nil
  end

  it 'counts no spend older than the window' do
    visit(100_00, at: Time.current - (8 * 86_400))

    expect(first_tolled_call).to eq(10)
  end

  it 'shares the count among the assistants of one account: nine calls by one, the 10th by another is tolled' do
    other = assistant_of(human)
    9.times { call }

    expect(tolled?(call(token(other)))).to be(true)
  end

  it 'shares the spend among the assistants of one account: at half the cap every 20th call across both is tolled' do
    visit(50_00)
    other = assistant_of(human)
    tolled = (1..40).select do |n|
      identity = token(n.odd? ? agent : other)
      answer = call(identity)
      pay(answer, identity) if tolled?(answer)
    end

    expect(tolled).to eq([20, 40])
  end

  it 'counts a fresh unbound assistant alone, on the account it got at registration' do
    9.times { call }
    unbound = register_client(OpenSSL::PKey.generate_key('ED25519'))

    expect(first_tolled_call(token(unbound))).to eq(10)
  end

  it "adds the calls of the assistant's previous account to its new account at a binding" do
    unbound = register_client(OpenSSL::PKey.generate_key('ED25519'))
    4.times { call(token(unbound)) }
    3.times { call }
    bound = Kiosk::Server::AccountBinding.bind!(agent_id: unbound.id, user_id: human)

    expect(first_tolled_call(token(bound))).to eq(3)
  end

  it 'gives each of the calls made at the same time its own number, so no two of them skip the proof' do
    account = human
    gate = Queue.new
    threads = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          described_class.count!(account)
        end
      end
    end
    4.times { gate << :go }

    expect(threads.map(&:value).sort).to eq([1, 2, 3, 4])
  end

  describe 'the answers that count' do
    let(:access_token) { client_credentials(agent.id, key:)[2].fetch('access_token') }

    before do
      declare_query('menu', input_schema: { type: 'object', properties: { size: { type: 'integer' } } }) do
        raise Kiosk::Server::Errors::NotFound, 'no such dish'
      end
    end

    # The status of `GET /kiosk/menu<query>` with `token`.
    def get_menu(query = '', token: access_token)
      path = '/kiosk/menu'
      url = "#{OauthClients::ISSUER}#{path}"
      env = Rack::MockRequest.env_for("#{url}#{query}", **dpop_env(token, method: 'GET', url:, key:))
      Kiosk::Server::Routing::VerbRoute.new(:query, 'menu').call(env).first
    end

    it 'counts no call refused before the toll: a refused token or arguments that do not match the schema' do
      expect([get_menu(token: 'not-a-token'), get_menu('?size=large')]).to eq([401, 400])
      expect(calls_since_proof).to be_nil
    end

    it 'counts a call that the operation itself refuses' do
      expect(get_menu).to eq(404)
      expect(calls_since_proof).to eq(1)
    end
  end
end
