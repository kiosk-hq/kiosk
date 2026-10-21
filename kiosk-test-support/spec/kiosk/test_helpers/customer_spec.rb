# frozen_string_literal: true

require 'kiosk/test_helpers/customer'

RSpec.describe Kiosk::TestHelpers::Customer do
  # A customer of one origin, with a signed credential for account u1.
  context 'with a customer' do
    subject(:customer) { Class.new(described_class).new(assistant, principal) }

    let(:origin)    { 'http://shop.example.com' }
    let(:assistant) { Kiosk::TestHelpers::Assistant.new(base_url: origin) }
    let(:principal) do
      Kiosk::TestHelpers::Assistant::Principal.new(agent_id: 'a1', user_id: 'u1', token: token('u1'), rsa_key: OpenSSL::PKey::RSA.generate(2048))
    end

    def token(account, agent: 'a1', role: 'customer') = JWT.encode({ sub: account, agent_id: agent, role: }, nil, 'none')

    def requests_to(method, path)
      sent = []
      [stub_request(method, "#{origin}#{path}").with { sent << it }, sent]
    end

    it 'reads whose account it acts for, and in which role, off its credential' do
      expect([customer.account, customer.role]).to eq(%w[u1 customer])
    end

    it 'does an action with headers of its own' do
      stub, sent = requests_to(:post, '/kiosk/add_todo')
      stub.to_return(json_return(200, 'todo_id' => 't1'))

      expect(customer.does(:add_todo, headers: { 'Kiosk-Timezone' => 'Europe/Istanbul' }, title: 'Tent')['todo_id']).to eq('t1')
      expect(sent.first.headers['Kiosk-Timezone']).to eq('Europe/Istanbul')
    end

    describe '#pays' do
      it 'pays the checkout an action answered with a checkout mandate and a payment mandate for it' do
        stub, sent = requests_to(:post, '/kiosk/pay')
        stub.to_return(json_return(200, 'status' => 'paid'))
        checkout_jwt = JWT.encode({ merchant: { id: origin, name: 'Shop' }, currency: 'eur', total_amount_cents: 450 },
                                  OpenSSL::PKey::RSA.generate(2048), 'PS256')

        expect(customer.pays(checkout_jwt)).to be_ok

        mandates = JSON.parse(sent.first.body).transform_values { Kiosk::TestHelpers::Mandate.content(it) }
        expect(mandates['checkout_mandate']).to include('checkout_jwt' => checkout_jwt)
        expect(mandates['payment_mandate']).to include('payment_amount' => { 'amount' => 450, 'currency' => 'eur' })
      end
    end

    describe '#asks' do
      let(:toll) { problem_return('pow_required', status: 402, challenges: [{ 'id' => 'c1' }]) }

      it 'answers an unpaid toll instead of paying it' do
        stub_request(:get, "#{origin}/kiosk/catalog").to_return(toll)

        expect(customer.asks(:catalog, unpaid: true)).to be_refused(:pow_required)
      end

      it 'carries the proofs it was given, once' do
        stub, sent = requests_to(:get, '/kiosk/catalog')
        stub.to_return(toll)

        customer.asks(:catalog, proofs: [{ challenge: 'c1', nonce: 7 }])

        expect(sent.map { JSON.parse(it.headers['Kiosk-Pow']) }).to eq([[{ 'challenge' => 'c1', 'nonce' => 7 }]])
      end
    end

    describe 'a new credential' do
      it 'redeems a link code, then holds the account the origin signed into a new token, as the same kind of customer' do
        claim, sent = requests_to(:post, '/kiosk/auth/claim')
        claim.to_return(status: 204)
        stub_request(:post, "#{origin}/kiosk/oauth/token").to_return(json_return(200, 'access_token' => token('alice', agent: 'a1')))

        linked = customer.redeems('LINK-1')

        expect(linked).to be_a(customer.class)
        expect(linked.principal).to have_attributes(user_id: 'alice', agent_id: 'a1', rsa_key: principal.rsa_key)
        expect(JSON.parse(sent.first.body)).to include('code' => 'LINK-1', 'client_assertion' => be_a(String))
      end

      it 'raises when the origin refuses the link code' do
        stub_request(:post, "#{origin}/kiosk/auth/claim").to_return(problem_return('not_found', status: 404))

        expect { customer.redeems('LINK-1') }.to raise_error(/did not redeem LINK-1: 404/)
      end

      it 'comes from a token request with its own key' do
        stub_request(:post, "#{origin}/kiosk/oauth/token").with(body: hash_including('grant_type' => 'client_credentials'))
                                                          .to_return(json_return(200, 'access_token' => token('u1', role: 'owner')))

        expect(customer.signs_back_in).to be_ok
        expect(customer.with_a_fresh_credential.role).to eq('owner')
      end

      it 'is refused once the assistant is no longer known' do
        stub_request(:post, "#{origin}/kiosk/oauth/token").to_return(json_return(401, 'error' => 'invalid_client'))

        expect(customer.signs_back_in).to be_refused(:invalid_client)
        expect { customer.with_a_fresh_credential }.to raise_error(/issued no credential: 401/)
      end
    end

    describe 'a newcomer' do
      it 'registers its key and holds no token yet' do
        stub_request(:post, "#{origin}/kiosk/oauth/register").to_return(json_return(201, 'client_id' => 'a2'))

        newcomer = described_class.newcomer(assistant)

        expect(newcomer.principal).to have_attributes(agent_id: 'a2', user_id: nil, token: nil)
      end
    end

    describe 'an identity check' do
      let(:news) { instance_double(Kiosk::TestHelpers::Assistant::Events, subscribe: nil) }
      let(:published) do
        { 'events' => [{ 'name' => 'kyc_verification', 'payload_schema' => { 'type' => 'object', 'required' => %w[status] } }] }
      end

      before do
        allow(assistant).to receive(:events).and_return(news)
        stub_request(:get, "#{origin}/kiosk/schema").to_return(json_return(200, published))
        stub_request(:post, "#{origin}/kiosk/request_kyc").to_return(json_return(200, 'request_id' => 'r1'))
      end

      def outcome(status) = allow(news).to receive(:await) { |&match| [{ 'topic' => 'kyc_verification', 'subject' => 'r1', 'data' => { 'status' => status } }].find(&match) }

      it 'listens for its outcome before asking for it' do
        allow(news).to receive(:subscribe) { expect(a_request(:post, "#{origin}/kiosk/request_kyc")).not_to have_been_made }

        expect(customer.requests_verification['request_id']).to eq('r1')
        expect(news).to have_received(:subscribe).with('kyc_verification')
      end

      it 'is heard to pass when the origin reports that check approved, and not otherwise' do
        customer.requests_verification

        outcome('approved')
        expect(customer.hears_verification_passed).to be(true)
        outcome('rejected')
        expect(customer.hears_verification_passed).to be(false)
      end
    end

    describe '#hears' do
      let(:news) { instance_double(Kiosk::TestHelpers::Assistant::Events) }
      let(:published) do
        { 'events' => [{ 'name' => 'todo', 'payload_schema' => { 'type' => 'object', 'required' => %w[action],
                                                                 'properties' => { 'action' => { 'enum' => %w[added completed] } } } }] }
      end

      before { stub_request(:get, "#{origin}/kiosk/schema").to_return(json_return(200, published)) }

      def heard(*events) = allow(news).to receive(:await) { |&match| events.find(&match) }

      it 'answers the news that matches, in the shape the origin publishes' do
        heard({ 'topic' => 'todo', 'subject' => 'l1', 'data' => { 'action' => 'added' } },
              { 'topic' => 'todo', 'subject' => 'l1', 'data' => { 'action' => 'completed' } })

        expect(customer.hears(:todo, about: 'l1', on: news, action: 'completed')).to eq('action' => 'completed')
      end

      it 'refuses news off the published shape' do
        heard({ 'topic' => 'todo', 'data' => { 'action' => 'deleted' } })

        expect { customer.hears(:todo, on: news) }.to raise_error(Kiosk::TestHelpers::Assistant::Events::Error, /off its schema: todo: /)
      end
    end
  end

  describe Kiosk::TestHelpers::Answer do
    def answer(status, body, headers: {}, proofs: 0)
      described_class.new(Kiosk::TestHelpers::Wire::Response.new(status:, body:, headers:, proofs:))
    end

    it "is refused on a problem document's code or an OAuth error, never when it succeeded" do
      expect(answer(403, { 'code' => 'forbidden' })).to be_refused(:forbidden)
      expect(answer(400, { 'error' => 'authorization_pending' })).to be_refused(:authorization_pending)
      expect(answer(200, { 'code' => 'forbidden' })).not_to be_refused(:forbidden)
    end

    it 'reads the detail, a header, the tolls paid and the next page' do
      page = answer(200, [], headers: { 'link' => '<https://h.example/kiosk/search?cursor=x>; rel="next"', 'x-total-count' => '9' }, proofs: 2)

      expect([page.next_page, page.header('X-Total-Count'), page.tolls_paid]).to eq(['https://h.example/kiosk/search?cursor=x', '9', 2])
      expect(answer(200, []).next_page).to be_nil
      expect(answer(400, { 'detail' => 'no such slot' }).detail).to eq('no such slot')
    end

    it 'solves the toll a refusal demands, one proof per challenge' do
      allow(Kiosk::Pow::Equihash).to receive(:solve) { { 'indices' => [it['id']] } }

      expect(answer(402, { 'code' => 'pow_required', 'challenges' => [{ 'id' => 1 }, { 'id' => 2 }] }).solved_toll)
        .to eq([{ challenge: { 'id' => 1 }, nonce: { 'indices' => [1] } }, { challenge: { 'id' => 2 }, nonce: { 'indices' => [2] } }])
    end

    it 'inspects as its status and body' do
      expect(answer(404, { 'code' => 'not_found' }).inspect).to eq('404 {"code" => "not_found"}')
    end
  end
end
