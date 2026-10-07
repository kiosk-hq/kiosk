# frozen_string_literal: true

require "json"
require "net/http"
require "kiosk/redteam/stripe_mock"

RSpec.describe Kiosk::Redteam::StripeMock do
  before do
    skip "stripe-mock not installed (brew install stripe-mock)" unless system("command -v stripe-mock >/dev/null 2>&1")
    WebMock.allow_net_connect!
  end

  after { WebMock.disable_net_connect! }

  def post(path, form)
    uri = URI("#{described_class.start}#{path}")
    req = Net::HTTP::Post.new(uri)
    req.basic_auth("sk_test_mock", "")
    req.set_form_data(form)
    JSON.parse(Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }.body)
  end

  it "answers the base URL of a listening stripe-mock" do
    expect(described_class.start).to eq("http://127.0.0.1:12111")
    expect(described_class.listening?).to be(true)
  end

  it "answers a confirmed PaymentIntent as Stripe does for a test card: succeeded, whole amount received" do
    intent = post("/v1/payment_intents", amount: 1599, currency: "eur", customer: "cus_x",
                                         payment_method: "pm_card_visa", confirm: true, off_session: true)
    expect(intent.values_at("status", "amount", "amount_received")).to eq(["succeeded", 1599, 1599])
  end

  it "leaves an unconfirmed PaymentIntent as stripe-mock answers it" do
    intent = post("/v1/payment_intents", amount: 1599, currency: "eur")
    expect(intent.values_at("status", "amount_received")).to eq(["requires_payment_method", 0])
  end
end
