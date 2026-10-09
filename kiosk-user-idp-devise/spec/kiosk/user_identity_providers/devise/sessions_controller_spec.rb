# frozen_string_literal: true

require_relative "../../../support/signpost_app"

RSpec.describe Kiosk::UserIdentityProviders::Devise::SessionsController do
  include SignpostRequests

  it "answers a JSON sign-out with no session with a 401 pointing at the discovery document" do
    res = dispatch("DELETE", "/users/sign_out", { "HTTP_ACCEPT" => "application/json" })

    expect(res.status).to eq(401)
    expect(res.media_type).to eq("application/json")
    error = JSON.parse(res.body).fetch("error")
    expect(error).to include("code" => "not_signed_in")
    expect(error.fetch("hint")).to include("http://shop.example/.well-known/kiosk.json")
  end

  it "leaves a browser's sign-out to Devise's redirect" do
    res = dispatch("DELETE", "/users/sign_out", SignpostRequests::BROWSER)

    expect(res).to be_redirect
    expect(res.location).to eq("http://shop.example/")
  end
end
