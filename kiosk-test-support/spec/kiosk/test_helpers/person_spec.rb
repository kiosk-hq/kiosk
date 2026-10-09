# frozen_string_literal: true

require "kiosk/test_helpers/customer"
require "kiosk/test_helpers/person"

RSpec.describe Kiosk::TestHelpers::Person do
  subject(:alice) { described_class.new(origin, email: "alice@example.com", password: "secret") }

  let(:origin) { "http://site.example.com" }
  let(:form)   { '<form><input name="authenticity_token" value="csrf-1"></form>' }

  before do
    stub_request(:get, "#{origin}/users/sign_in").to_return(status: 200, body: form, headers: { "Set-Cookie" => "_session=s1" })
    stub_request(:post, "#{origin}/users/sign_in").to_return(status: 302, headers: { "Set-Cookie" => "_session=s2" })
  end

  it "signs in through the site's own form" do
    alice

    expect(a_request(:post, "#{origin}/users/sign_in")
      .with(body: hash_including("user" => { "email" => "alice@example.com", "password" => "secret" }, "authenticity_token" => "csrf-1")))
      .to have_been_made
  end

  it "mints a link code over the signed-in session, which the assistant redeems" do
    stub_request(:post, "#{origin}/kiosk/auth/link").with(headers: { "Cookie" => "_session=s2" })
                                                    .to_return(json_return(201, "link_code" => "LINK-1"))
    customer = instance_double(Kiosk::TestHelpers::Customer)
    allow(customer).to receive(:redeems).with("LINK-1").and_return(:linked)

    expect(alice.links(customer)).to eq(:linked)
  end

  it "approves a code on the verification page, with the page's CSRF token" do
    stub_request(:get, "#{origin}/kiosk/oauth/device/verify?user_code=U-1").to_return(status: 200, body: form)
    approval = stub_request(:post, "#{origin}/kiosk/oauth/device/verify")
               .with(body: { "user_code" => "U-1", "decision" => "approve", "authenticity_token" => "csrf-1" })
               .to_return(status: 200)

    alice.approves("U-1")

    expect(approval).to have_been_requested
  end

  it "says so when the site does not approve" do
    stub_request(:get, "#{origin}/kiosk/oauth/device/verify?user_code=U-1").to_return(status: 404)
    stub_request(:post, "#{origin}/kiosk/oauth/device/verify").to_return(status: 422)

    expect { alice.approves("U-1") }.to raise_error(/did not approve U-1: 404, 422/)
  end

  it "unlinks an assistant by its agent id" do
    principal = Kiosk::TestHelpers::Assistant::Principal.new(agent_id: "a1", user_id: "alice", token: nil, rsa_key: nil)
    unlink = stub_request(:post, "#{origin}/kiosk/auth/unlink").with(body: { agent_id: "a1" }.to_json).to_return(status: 204)

    alice.unlinks(Kiosk::TestHelpers::Customer.new(nil, principal))

    expect(unlink).to have_been_requested
  end
end
