# frozen_string_literal: true

# `payment_setup`, served by the engine against the payment provider port, and
# the page the human's browser returns to from the provider's setup page.

require "rack/mock"
require "json"

RSpec.describe Kiosk::Server::PaymentSetup do
  let(:connection) { FakeConnection.new }
  let(:store)      { Kiosk::Server::EventStore.new }

  # Answers the port and nothing else, so an engine that reached past it fails.
  let(:provider_class) do
    Class.new(Kiosk::PaymentProviders::Base) do
      attr_accessor :required, :seen_return_url

      def setup_required?(user_id:) = required
      def setup_url(user_id:, return_url:)
        self.seen_return_url = return_url
        "https://psp.example/setup/#{user_id}"
      end
    end
  end

  let(:returning_provider_class) do
    Class.new(provider_class) do
      def setup_return_user_id(params) = params["ref"]
    end
  end

  def configure(provider)
    Kiosk.configure do |c|
      c.signing_key      = Kiosk::Server::SigningKey.generate
      c.issuer           = "https://shop.example"
      c.roles            = %i[customer]
      c.agent_idp        = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
      c.event_store      = store
      c.payment_provider = provider
    end
    Kiosk::Server::HandlerRegistrations.reload!([])
  end

  before do
    allow_any_instance_of(Kiosk::Server::VerbController)
      .to receive(:connection_for).and_return(connection)
  end

  def token
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
      audience: "https://shop.example",
    )
  end

  def dispatch(controller, action, env)
    status, headers, body = controller.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw]
  end

  def post_payment_setup
    env = Rack::MockRequest.env_for(
      "/kiosk/payment_setup", method: "POST", input: "{}",
      "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}",
    )
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/verb", action: "create", kiosk_verb: "payment_setup" }
    status, _headers, raw = dispatch(Kiosk::Server::VerbController, :create, env)
    [status, JSON.parse(raw)]
  end

  def get_return(query = "")
    env = Rack::MockRequest.env_for("/kiosk/payment_setup/return?#{query}")
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/payment_setup", action: "show" }
    dispatch(Kiosk::Server::PaymentSetupController, :show, env)
  end

  describe "an origin with no payment provider" do
    before { configure(nil) }

    it "publishes no payment_setup action" do
      expect(Kiosk::Server::Actions.known).not_to include("payment_setup")
    end

    it "answers POST payment_setup with 501 module_not_served" do
      status, problem = post_payment_setup
      expect(status).to eq(501)
      expect(problem["code"]).to eq("module_not_served")
    end

    it "answers the return page with 501 module_not_served" do
      status, = get_return
      expect(status).to eq(501)
    end
  end

  describe "an origin with a payment provider" do
    let(:provider) { provider_class.new }

    before { configure(provider) }

    it "answers ready when the provider needs no setup" do
      provider.required = false
      expect(post_payment_setup).to eq([200, { "status" => "ready" }])
    end

    it "answers setup_required with the provider's url, returning the human to the engine's page" do
      provider.required = true
      expect(post_payment_setup)
        .to eq([200, { "status" => "setup_required", "setup_url" => "https://psp.example/setup/u-1" }])
      expect(provider.seen_return_url).to eq("https://shop.example/kiosk/payment_setup/return")
    end

    it "publishes a descriptor with a backing-off poll cadence and a give-up horizon" do
      description = Kiosk::Server::Actions.describe("payment_setup")[:description]
      tiers = description.match(/re-check every ~(\d+) seconds for the first minute, then every ~(\d+) seconds/)
      expect(tiers).not_to be_nil
      expect(tiers[2].to_i).to be > tiers[1].to_i
      expect(description).to match(/GIVE UP after about \d+ minutes/)
    end

    it "declares no payment_setup topic when the provider cannot say who came back" do
      expect(Kiosk::Server::Events.known).not_to include("payment_setup")
    end
  end

  describe "the return page, with a provider that can say who came back" do
    let(:provider) { returning_provider_class.new }

    before { configure(provider) }

    it "declares the payment_setup topic" do
      expect(Kiosk::Server::Events.known).to include("payment_setup")
    end

    it "pushes payment_setup ready to the principal once the provider confirms readiness" do
      provider.required = false
      status, headers, body = get_return("ref=u-7")

      expect(status).to eq(200)
      expect(headers["content-type"]).to start_with("text/html")
      expect(body).to include("Your assistant can now pay")
      event = store.since("u-7", 0).first
      expect(event).to include("topic" => "payment_setup", "subject" => "u-7",
                               "data" => { "status" => "ready" })
    end

    it "pushes nothing while the provider still says setup is required" do
      provider.required = true
      status, = get_return("ref=u-7")
      expect(status).to eq(200)
      expect(store.head).to eq(0)
    end

    it "pushes nothing when the request names nobody" do
      status, = get_return
      expect(status).to eq(200)
      expect(store.head).to eq(0)
    end

    it "still renders the page when the provider raises" do
      allow(provider).to receive(:setup_return_user_id).and_raise("psp down")
      expect(Kiosk::Server::FailureLog).to receive(:report).with(/could not push payment_setup/, RuntimeError)
      status, _headers, body = get_return("ref=u-7")
      expect(status).to eq(200)
      expect(body).to include("Your assistant can now pay")
      expect(store.head).to eq(0)
    end
  end
end
