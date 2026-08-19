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
    ret = if status == 201
            json_return(201, "agent_id" => "a1", "user_id" => "u1", "access_token" => access_token)
          else
            problem_return("bad_request", status: status)
          end
    stub_request(:post, "#{BASE_URL}/kiosk/auth/register").to_return(ret)
  end

  it "injects the escalated role onto the register wire (attack simulation)" do
    stub = stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
           .with(body: hash_including("role" => "master"))
           .to_return(json_return(201, "agent_id" => "a1", "user_id" => "u1",
                                       "access_token" => token_with_role("customer")))

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

  # ── K-730 ────────────────────────────────────────────────────────────────
  #
  # A refusal of the injected registration is role-pinning only if an HONEST
  # registration would have succeeded. This block overturns the bare
  # "refuses outright → blocked: true" assertion below it: that reading was
  # demonstrated scoring BLOCKED against a server answering 404 on every path,
  # where no role is pinned because no agent is ever registered.
  context "when the server refuses the injected registration" do
    def register_returns(*responses)
      stub_request(:post, "#{BASE_URL}/kiosk/auth/register").to_return(*responses)
    end

    # Every refusal on the auth plane is an RFC 9457 problem document too —
    # the paths and SUCCESS bodies survived the cutover, the error shape did not.
    def refused(status, code = nil)
      problem_return(code || STATUS_DEFAULT_CODE.fetch(status), status: status)
    end

    def issued
      json_return(201, "agent_id" => "a1", "user_id" => "u1",
                       "access_token" => token_with_role("customer"))
    end

    it "returns blocked: true when the CONTROL registration succeeds (no escalation possible)" do
      register_returns(refused(400), issued)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(true)
      expect(verdict.status).to eq(400)
    end

    it "returns blocked: false when the server 404s every path" do
      register_returns(refused(404))

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("CONTROL FAILED")
    end

    it "returns blocked: false when the control is refused too" do
      register_returns(refused(400), refused(400))

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("CONTROL FAILED")
    end

    it "returns blocked: false on a 500 without spending a control registration" do
      stub = register_returns(refused(500))

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("a crash is not a gate")
      expect(stub).to have_been_requested.once
    end

    it "does not spend a control registration when the server issues a token" do
      stub = register_returns(issued)

      expect(scenario.call(client, profile).blocked).to be(true)
      expect(stub).to have_been_requested.once
    end
  end
end
