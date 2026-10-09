# frozen_string_literal: true

require "kiosk/test_helpers/customer"

RSpec.describe Kiosk::TestHelpers::Customer do
  subject(:customer) { shopper.new(assistant, principal) }

  let(:shopper)   { Class.new(described_class) }
  let(:origin)    { "http://shop.example.com" }
  let(:assistant) { Kiosk::TestHelpers::Assistant.new(base_url: origin) }
  let(:key)       { OpenSSL::PKey::RSA.generate(2048) }
  let(:principal) { Kiosk::TestHelpers::Assistant::Principal.new(agent_id: "a1", user_id: "u1", token: token("u1"), rsa_key: key) }

  def token(account, agent: "a1", role: "customer") = JWT.encode({ sub: account, agent_id: agent, role: }, nil, "none")

  def requests_to(method, path)
    sent = []
    [stub_request(method, "#{origin}#{path}").with { sent << _1 }, sent]
  end

  before { stub_request(:get, %r{/kiosk/auth/challenge}).to_return(json_return(200, "challenge" => "nonce-1")) }

  it "reads whose account it acts for, and in which role, off its credential" do
    expect([customer.account, customer.role]).to eq(%w[u1 customer])
  end

  describe "#asks" do
    let(:toll) { problem_return("pow_required", status: 402, challenges: [{ "id" => "c1" }]) }

    it "answers an unpaid toll instead of paying it" do
      stub_request(:get, "#{origin}/kiosk/catalog").to_return(toll)

      expect(customer.asks(:catalog, unpaid: true)).to be_refused(:pow_required)
    end

    it "carries the proofs it was given, once" do
      stub, sent = requests_to(:get, "/kiosk/catalog")
      stub.to_return(toll)

      customer.asks(:catalog, proofs: [{ challenge: "c1", nonce: 7 }])

      expect(sent.map { JSON.parse(_1.headers["Kiosk-Pow"]) }).to eq([[{ "challenge" => "c1", "nonce" => 7 }]])
    end
  end

  it "does an action with headers of its own" do
    stub, sent = requests_to(:post, "/kiosk/add_todo")
    stub.to_return(json_return(200, "todo_id" => "t1"))

    expect(customer.does(:add_todo, headers: { "Kiosk-Timezone" => "Europe/Istanbul" }, title: "Tent")["todo_id"]).to eq("t1")
    expect(sent.first.headers["Kiosk-Timezone"]).to eq("Europe/Istanbul")
  end

  it "pays a quote with an intent capped at the total and a cart that lists what it buys" do
    stub, sent = requests_to(:post, "/kiosk/pay")
    stub.to_return(json_return(200, "status" => "paid"))

    expect(customer.pays(total: 450, scope: "grocery", line_items: [{ order_id: "o1" }])).to be_ok

    signed = JSON.parse(sent.first.body).transform_values { JWT.decode(_1, key.public_key, true, algorithm: "RS256").first }
    intent, cart, payment = signed.values_at("intent_mandate_jws", "cart_mandate_jws", "payment_mandate_jws")
    expect(intent).to include("scope" => "grocery", "cap_amount_cents" => 450, "currency" => "eur", "iss" => origin,
                              "user_id" => "u1", "agent_id" => "a1")
    expect(cart).to include("intent_mandate_id" => intent["id"], "total_amount_cents" => 450, "line_items" => [{ "order_id" => "o1" }])
    expect(payment).to include("cart_mandate_id" => cart["id"], "amount_cents" => 450)
  end

  describe "a new credential" do
    it "holds the account the origin signed into it, as the same kind of customer" do
      stub, sent = requests_to(:post, "/kiosk/auth/claim")
      stub.to_return(json_return(201, "access_token" => token("alice", agent: "a1")))

      linked = customer.redeems("LINK-1")

      expect(linked).to be_a(shopper)
      expect(linked.principal).to have_attributes(user_id: "alice", agent_id: "a1", rsa_key: key)
      expect(JSON.parse(sent.first.body)).to include("code" => "LINK-1", "public_key" => key.public_key.to_pem)
    end

    it "comes from signing back in with its own key" do
      stub_request(:post, "#{origin}/kiosk/auth/login").to_return(json_return(200, "access_token" => token("u1", role: "owner")))

      expect(customer.signs_back_in).to be_ok
      expect(customer.with_a_fresh_credential.role).to eq("owner")
    end

    it "is refused once the assistant is no longer known" do
      stub_request(:post, "#{origin}/kiosk/auth/login").to_return(problem_return("not_found", status: 404))

      expect(customer.signs_back_in).to be_refused(:not_found)
      expect { customer.with_a_fresh_credential }.to raise_error(/issued no credential: 404/)
    end

    it "is collected once the person approves the code the assistant showed" do
      stub_request(:post, "#{origin}/kiosk/oauth/device_authorization").to_return(json_return(200, "device_code" => "d1", "user_code" => "U-1"))
      polls = stub_request(:post, "#{origin}/kiosk/oauth/token").with(body: hash_including("device_code" => "d1"))
                                                                .to_return(json_return(400, "error" => "authorization_pending"),
                                                                           json_return(200, "access_token" => token("alice")))
      request = customer.asks_to_be_linked

      expect(customer.polls(request)).to be_refused(:authorization_pending)
      expect(customer.collects(request).account).to eq("alice")
      expect(polls).to have_been_requested.twice
    end
  end

  describe "#hears" do
    let(:news) { instance_double(Kiosk::TestHelpers::Assistant::Events) }
    let(:published) do
      { "events" => [{ "name" => "todo", "payload_schema" => { "type" => "object", "required" => %w[action],
                                                               "properties" => { "action" => { "enum" => %w[added completed] } } } }] }
    end

    before { stub_request(:get, "#{origin}/kiosk/schema").to_return(json_return(200, published)) }

    def heard(*events) = allow(news).to receive(:await) { |&match| events.find(&match) }

    it "answers the news that matches, in the shape the origin publishes" do
      heard({ "topic" => "todo", "subject" => "l1", "data" => { "action" => "added" } },
            { "topic" => "todo", "subject" => "l1", "data" => { "action" => "completed" } })

      expect(customer.hears(:todo, about: "l1", on: news, action: "completed")).to eq("action" => "completed")
    end

    it "refuses news off the published shape" do
      heard({ "topic" => "todo", "data" => { "action" => "deleted" } })

      expect { customer.hears(:todo, on: news) }.to raise_error(Kiosk::TestHelpers::Assistant::Events::Error, /off its schema: todo: /)
    end
  end
end

RSpec.describe Kiosk::TestHelpers::Answer do
  def answer(status, body, headers: {}, proofs: 0)
    described_class.new(Kiosk::TestHelpers::Wire::Response.new(status:, body:, headers:, proofs:))
  end

  it "is refused on a problem document's code or an OAuth error, never when it succeeded" do
    expect(answer(403, { "code" => "forbidden" })).to be_refused(:forbidden)
    expect(answer(400, { "error" => "authorization_pending" })).to be_refused(:authorization_pending)
    expect(answer(200, { "code" => "forbidden" })).not_to be_refused(:forbidden)
  end

  it "reads the detail, a header, the tolls paid and the next page" do
    page = answer(200, [], headers: { "link" => '<https://h.example/kiosk/search?cursor=x>; rel="next"', "x-total-count" => "9" }, proofs: 2)

    expect([page.next_page, page.header("X-Total-Count"), page.tolls_paid]).to eq(["https://h.example/kiosk/search?cursor=x", "9", 2])
    expect(answer(200, []).next_page).to be_nil
    expect(answer(400, { "detail" => "no such slot" }).detail).to eq("no such slot")
  end

  it "solves the toll a refusal demands, one proof per challenge" do
    allow(Kiosk::Pow::Equihash).to receive(:solve) { { "indices" => [_1["id"]] } }

    expect(answer(402, { "code" => "pow_required", "challenges" => [{ "id" => 1 }, { "id" => 2 }] }).solved_toll)
      .to eq([{ challenge: { "id" => 1 }, nonce: { "indices" => [1] } }, { challenge: { "id" => 2 }, nonce: { "indices" => [2] } }])
  end

  it "inspects as its status and body" do
    expect(answer(404, { "code" => "not_found" }).inspect).to eq('404 {"code" => "not_found"}')
  end
end
