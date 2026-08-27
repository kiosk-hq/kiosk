# frozen_string_literal: true

require "spec_helper"
require "base64"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection do
  subject(:scenario) { described_class.new }

  let(:client)     { Kiosk::Redteam::Client.new(base_url: BASE_URL) }
  let(:profile)    { minimal_profile(declared_roles: %w[customer owner]) }
  let(:device_url) { "#{BASE_URL}/kiosk/oauth/device_authorization" }

  # A JWS whose payload carries the given role claim — the scenario reads the
  # claim without verifying, so the signature segment is irrelevant.
  def token_with_role(role)
    payload = Base64.urlsafe_encode64(JSON.generate("role" => role)).delete("=")
    "eyJhbGciOiJSUzI1NiJ9.#{payload}.sig"
  end

  def stub_register(role: "customer", status: 201)
    ret = if status == 201
            json_return(201, "agent_id" => "a1", "user_id" => "u1",
                             "access_token" => token_with_role(role))
          else
            problem_return(STATUS_DEFAULT_CODE.fetch(status), status: status)
          end
    stub_request(:post, "#{BASE_URL}/kiosk/auth/register").to_return(ret)
  end

  # RFC 6749 error object — NOT a Kiosk problem document. The OAuth half of the
  # binding ceremony is the spec's one deliberate exception, which is exactly
  # why `Kiosk::Redteam.blocked?` cannot judge these answers.
  def oauth_error(error = "invalid_request")
    { status:  400,
      body:    JSON.generate("error" => error, "error_description" => "role is not accepted here"),
      headers: { "Content-Type" => "application/json" } }
  end

  def opened(user_code = "WDJB-MJHT")
    json_return(200,
                "device_code"      => "dc-1", "user_code" => user_code,
                "verification_uri" => "#{BASE_URL}/kiosk/oauth/device/verify",
                "expires_in"       => 900, "interval" => 5)
  end

  # The engine at head: any non-empty role/scope is refused, the role-less
  # request opens the ceremony.
  #
  # WebMock resolves the MOST RECENTLY DECLARED matching stub, so the general
  # answer is registered first and the narrower one last — the other order
  # makes every stub in this file a no-op that a "blocked: false" expectation
  # would happily accept.
  def stub_fixed_engine
    stub_request(:post, device_url).to_return(opened)
    stub_request(:post, device_url)
      .with { |req| req.body.to_s.match?(/(\A|&)(role|scope)=[^&]+/) }
      .to_return(oauth_error)
  end

  before { stub_register }

  it "is BLOCKED against the engine at head" do
    stub_fixed_engine

    verdict = scenario.call(client, profile)

    expect(verdict.blocked).to be(true)
    expect(verdict.skipped).to be(false)
    expect(verdict.status).to eq(400)
  end

  it "probes each DECLARED role under both the role= and scope= spellings" do
    stub_fixed_engine

    scenario.call(client, profile)

    %w[role scope].each do |param|
      %w[customer owner].each do |role|
        expect(a_request(:post, device_url).with(body: hash_including(param => role)))
          .to have_been_made.at_least_once
      end
    end
  end

  # THE REGRESSION THIS FILE EXISTS FOR (K-072). The vulnerable engine refused
  # an UNDECLARED role and honoured a declared one, so a battery probing only
  # `role=master` printed BLOCKED against a live escalation.
  context "against the PRE-K-072 engine (a declared role is honoured)" do
    def stub_vulnerable_engine
      stub_request(:post, device_url).to_return(opened)
      stub_request(:post, device_url)
        .with { |req| req.body.to_s.match?(/(\A|&)(role|scope)=master/) }
        .to_return(oauth_error)
    end

    it "returns blocked: false and names the answer the declared role got" do
      stub_vulnerable_engine

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("role=owner (DECLARED")
      expect(verdict.detail).to include("HTTP 200")
    end
  end

  # `params[:role] || params[:scope]` was the vulnerable read, so a fix that
  # guarded only one spelling must still fail here.
  context "when only `role` is guarded and `scope` still passes" do
    it "returns blocked: false" do
      stub_request(:post, device_url).to_return(opened)
      stub_request(:post, device_url)
        .with { |req| req.body.to_s.match?(/(\A|&)role=[^&]+/) }
        .to_return(oauth_error)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("scope=customer (DECLARED")
    end
  end

  # A refusal is free: an origin that refuses EVERY device_authorization must
  # not score a pass here.
  context "when the origin refuses the role-less request too" do
    it "returns blocked: false and shows the control failing" do
      stub_request(:post, device_url).to_return(oauth_error)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("CONTROL role-less request -> HTTP 400")
    end
  end

  # The wire-derived floor: a stale/empty `declared_roles` must not make the
  # probe set vacuous.
  context "when the profile declares no roles" do
    let(:profile) { minimal_profile }

    it "still probes the role the origin's own registration token carries" do
      stub_fixed_engine

      expect(scenario.call(client, profile).blocked).to be(true)
      expect(a_request(:post, device_url).with(body: hash_including("role" => "customer")))
        .to have_been_made.at_least_once
    end

    it "is a BREACH when that wire-derived role is honoured" do
      stub_request(:post, device_url).to_return(opened)
      stub_request(:post, device_url)
        .with { |req| req.body.to_s.match?(/(\A|&)(role|scope)=master/) }
        .to_return(oauth_error)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('"customer" read off this origin')
    end

    it "SKIPS — not passes — when the origin declares no role at all" do
      stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
        .to_return(json_return(201, "agent_id" => "a1", "user_id" => "u1",
                                    "access_token" => "eyJhbGciOiJSUzI1NiJ9.e30.sig"))

      verdict = scenario.call(client, profile)

      expect(verdict.skipped).to be(true)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("declares no role")
    end
  end

  context "when the control registration does not succeed" do
    it "returns a SETUP FAILED verdict rather than falling back to the vacuous probe" do
      stub_register(status: 404)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.skipped).to be(false)
      expect(verdict.detail).to include("SETUP FAILED")
      expect(a_request(:post, device_url)).not_to have_been_made
    end
  end
end
