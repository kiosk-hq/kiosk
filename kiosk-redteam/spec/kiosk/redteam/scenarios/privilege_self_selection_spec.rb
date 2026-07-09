# frozen_string_literal: true

require "spec_helper"
require "base64"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::PrivilegeSelfSelection do
  subject(:scenario) { described_class.new }

  let(:client)  { Kiosk::Redteam::Client.new(base_url: BASE_URL) }
  let(:profile) { minimal_profile }

  # A JWS whose payload carries the given role claim (signature is irrelevant —
  # the scenario reads the claim without verifying).
  def token_with_role(role)
    payload = Base64.urlsafe_encode64(JSON.generate("role" => role)).delete("=")
    "eyJhbGciOiJSUzI1NiJ9.#{payload}.sig"
  end

  before do
    # PoP handshake: the challenge fetch always succeeds.
    stub_request(:get, %r{#{Regexp.escape(BASE_URL)}/kiosk/auth/challenge})
      .to_return(
        status:  200,
        body:    JSON.generate("challenge" => "nonce-1"),
        headers: { "Content-Type" => "application/json" },
      )
  end

  def stub_register_returning(access_token, status: 201)
    body = if status == 201
             { "agent_id" => "a1", "user_id" => "u1", "access_token" => access_token }
           else
             { "error" => { "code" => "bad_request" } }
           end
    stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
      .to_return(status: status, body: JSON.generate(body),
                 headers: { "Content-Type" => "application/json" })
  end

  it "injects the escalated role onto the register wire (attack simulation)" do
    stub = stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
           .with(body: hash_including("role" => "master"))
           .to_return(status: 201,
                      body: JSON.generate("agent_id" => "a1", "user_id" => "u1",
                                          "access_token" => token_with_role("customer")),
                      headers: { "Content-Type" => "application/json" })

    scenario.call(client, profile)
    expect(stub).to have_been_requested
  end

  context "when the server IGNORES the injected role (pinned server-side — correct)" do
    it "returns blocked: true" do
      stub_register_returning(token_with_role("customer"))
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(true)
    end
  end

  context "when the server HONOURS the injected role (escalation — BREACH)" do
    it "returns blocked: false and names the escalated role" do
      stub_register_returning(token_with_role("master"))
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to match(/master/)
    end
  end

  context "when the server refuses the registration outright" do
    it "returns blocked: true (no escalation possible)" do
      stub_register_returning(nil, status: 400)
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(true)
    end
  end
end
