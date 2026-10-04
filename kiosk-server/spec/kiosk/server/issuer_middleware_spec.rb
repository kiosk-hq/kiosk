# frozen_string_literal: true

require "rack/mock"

RSpec.describe Kiosk::Server::IssuerMiddleware do
  subject(:middleware) { described_class.new(->(_env) { [200, {}, [Kiosk.current_issuer.to_s]] }) }

  before do
    Kiosk.configure do |c|
      c.issuer = "https://getgrocery.example"
      c.additional_origins = ["https://buymilk.example"]
    end
  end

  def issuer_for(url, headers = {})
    _, _, body = middleware.call(Rack::MockRequest.env_for(url, headers))
    body.first
  end

  it "resolves a listed origin to itself" do
    expect(issuer_for("https://buymilk.example/kiosk/catalog")).to eq("https://buymilk.example")
  end

  it "resolves the default origin to the issuer" do
    expect(issuer_for("https://getgrocery.example/.well-known/kiosk.json")).to eq("https://getgrocery.example")
  end

  it "resolves an origin the operator does not serve to the issuer" do
    expect(issuer_for("http://www.example.com/kiosk/catalog")).to eq("https://getgrocery.example")
  end

  it "reads the scheme a TLS-terminating proxy forwarded" do
    expect(issuer_for("http://buymilk.example/kiosk/catalog",
                      "HTTP_HOST" => "buymilk.example", "HTTP_X_FORWARDED_PROTO" => "https"))
      .to eq("https://buymilk.example")
  end

  it "leaves no issuer behind once the request is served" do
    issuer_for("https://buymilk.example/kiosk/catalog")
    expect(Kiosk.current_issuer).to eq("https://getgrocery.example")
  end
end
