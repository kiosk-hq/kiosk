# frozen_string_literal: true

# THE DECLINED-BINDING PROFILE (protocol.md §16.1 item 7).
#
# Binding is an OPTIONAL module, and an operator that does not serve it answers
# `501 module_not_served` at the published paths it would have served. This file
# pins both halves of `c.serve_account_binding`: OFF, every binding endpoint
# answers that one problem document, including the `/oauth/*` pair whose only
# Kiosk problem document this is; ON, nothing moves, and the four kiosk-pop auth
# endpoints are untouched either way because they are CORE.
#
# Dispatch via `ActionController::Metal.action(...)`, the harness the other
# controller specs use. The refusal runs before anything reads the request, so
# no example here needs a body, a session or a database.

require "rack/mock"
require "json"
require "openssl"

RSpec.describe "the declined account-binding profile" do
  let(:store) { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }

  before do
    Kiosk.configure do |c|
      c.issuer                     = "https://provider.example"
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
  end

  def decline_binding!
    Kiosk.configure { |c| c.serve_account_binding = false }
  end

  def dispatch(controller, action, method, path)
    env = Rack::MockRequest.env_for("https://provider.example#{path}", method: method)
    env["rack.session"] = {}
    status, headers, raw = controller.action(action).call(env)
    body = +""
    raw.each { |chunk| body << chunk }
    [status, headers, body]
  end

  # Every binding route the engine draws, by the controller action that answers
  # it. The two the spec names by URL — `device_authorization_url` and
  # `claim_url` — head the list; the rest are the same module and decline with
  # it, because an origin still minting link codes is serving binding.
  BINDING_ENDPOINTS = [
    ["POST", "/kiosk/oauth/device_authorization", "OauthDeviceAuthorizationController", :create],
    ["POST", "/kiosk/auth/claim",                 "AuthController",                     :claim],
    ["POST", "/kiosk/oauth/token",                "OauthTokenController",               :create],
    ["GET",  "/kiosk/oauth/device/verify",        "DeviceVerifyController",             :show],
    ["POST", "/kiosk/oauth/device/verify",        "DeviceVerifyController",             :create],
    ["POST", "/kiosk/auth/link",                  "AuthController",                     :link],
    ["POST", "/kiosk/auth/unlink",                "AuthController",                     :unlink],
    ["GET",  "/kiosk/auth/assistants",            "AssistantsController",               :show],
    ["POST", "/kiosk/auth/assistants/link",       "AssistantsController",               :link],
    ["POST", "/kiosk/auth/assistants/update",     "AssistantsController",               :update],
    ["POST", "/kiosk/auth/assistants/unlink",     "AssistantsController",               :unlink],
  ].freeze

  describe "with the module declined" do
    BINDING_ENDPOINTS.each do |method, path, controller_name, action|
      it "answers #{method} #{path} with 501 module_not_served" do
        decline_binding!
        controller = Kiosk::Server.const_get(controller_name)
        status, headers, body = dispatch(controller, action, method, path)

        expect(status).to eq(501)
        expect(headers["Content-Type"]).to include("application/problem+json")

        problem = JSON.parse(body, symbolize_names: true)
        expect(problem[:code]).to   eq("module_not_served")
        expect(problem[:status]).to eq(501)
        expect(problem[:type]).to   eq("https://kiosk.tech/problems/module_not_served")
        # `detail` NAMES the module: it is the only thing telling "no binding
        # here" from "no payments here" to whoever reads the answer.
        expect(problem[:detail]).to include("account binding")
      end
    end

    it "still serves the four core kiosk-pop auth endpoints" do
      decline_binding!
      status, = dispatch(
        Kiosk::Server::AuthController, :challenge, "GET",
        "/kiosk/auth/challenge?public_key=#{CGI.escape(OpenSSL::PKey::RSA.generate(2048).public_key.to_pem)}",
      )
      expect(status).to eq(200)
    end

    # §4.3: the auth block is CORE discovery. All six URLs are published by
    # every conformant origin whether or not it serves what the last two reach,
    # and `capabilities` has no binding member — so an assistant cannot read
    # the discovery document as a capability check and has to dial and branch.
    it "publishes all six auth URLs and adds no capability for binding" do
      decline_binding!
      auth = Kiosk::Server::WellKnown.build(base_url: "https://provider.example")
                                     .fetch(:kiosk).fetch(:auth)

      expect(auth.keys).to include(
        :challenge_url, :register_url, :login_url, :revoke_url,
        :device_authorization_url, :claim_url
      )
      expect(auth[:device_authorization_url])
        .to eq("https://provider.example/kiosk/oauth/device_authorization")
      expect(auth[:claim_url]).to eq("https://provider.example/kiosk/auth/claim")
    end
  end

  describe "with the module served (the default)" do
    it "defaults to true, so no configured origin moves" do
      expect(Kiosk.configuration.serve_account_binding).to be(true)
    end

    it "opens a claim ceremony rather than refusing it" do
      pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
      env = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/oauth/device_authorization",
        method: "POST", params: { "client_id" => "assistant", "public_key" => pem },
      )
      status, _headers, raw = Kiosk::Server::OauthDeviceAuthorizationController
                              .action(:create).call(env)
      body = +""
      raw.each { |chunk| body << chunk }

      expect(status).to eq(200)
      expect(JSON.parse(body, symbolize_names: true)[:device_code]).to be_a(String)
    end

    # The OAuth wire is unchanged when the module IS served: a malformed call
    # gets the OAuth error object, not a problem document. `module_not_served`
    # is the single carve-out, and this is the control that says so.
    it "keeps the OAuth error object for an ordinary refusal" do
      env = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/oauth/device_authorization",
        method: "POST", params: { "client_id" => "assistant" },
      )
      status, headers, raw = Kiosk::Server::OauthDeviceAuthorizationController
                             .action(:create).call(env)
      body = +""
      raw.each { |chunk| body << chunk }

      expect(status).to eq(400)
      expect(headers["Content-Type"]).not_to include("problem+json")
      expect(JSON.parse(body, symbolize_names: true)[:error]).to eq("invalid_request")
    end
  end
end
