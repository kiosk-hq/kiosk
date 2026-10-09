# frozen_string_literal: true

require_relative "../../../support/signpost_app"

RSpec.describe Kiosk::UserIdentityProviders::Devise::WireSignpost do
  include SignpostRequests

  let(:credentials) { JSON.generate(user: { email: "probe@example.com", password: "probe" }) }

  it "answers a JSON sign-in POST without a CSRF token with a 422 pointing at the discovery document" do
    res = dispatch("POST", "/users/sign_in", SignpostRequests::JSON_CALLER, input: credentials)

    expect(res.status).to eq(422)
    expect(res.media_type).to eq("application/json")
    error = JSON.parse(res.body).fetch("error")
    expect(error).to include("code" => "invalid_authenticity_token")
    expect(error.fetch("hint")).to include("http://shop.example/.well-known/kiosk.json")
  end

  it "answers any JSON POST to a CSRF-protected page the same way" do
    res = dispatch("POST", "/probe", { "CONTENT_TYPE" => "application/json" }, input: "{}")

    expect(res.status).to eq(422)
    expect(JSON.parse(res.body).dig("error", "code")).to eq("invalid_authenticity_token")
  end

  it "leaves a browser's forged POST to Rails" do
    expect { dispatch("POST", "/users/sign_in", SignpostRequests::BROWSER, input: "user[email]=a") }
      .to raise_error(ActionController::InvalidAuthenticityToken)
  end
end
