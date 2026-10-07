# frozen_string_literal: true

# The KYC module against a real Postgres: `request_kyc`, the provider's
# callback, the `kyc_verification` event and the grants, keyed on the person.

require "active_record"
require "json"
require "jwt"
require "openssl"
require "rack/mock"
require "securerandom"

RSpec.describe Kiosk::Server::Kyc do
  KYC_SPEC_SCHEMA = "kiosk_kyc_spec"

  def self.postgres_error
    @postgres_error ||= begin
      ::ActiveRecord::Base.establish_connection(
        adapter: "postgresql", host: ENV["PGHOST"], username: ENV["PGUSER"],
        password: ENV["PGPASSWORD"], database: ENV.fetch("PGDATABASE", "postgres"),
      )
      ::ActiveRecord::Base.connection.execute("SELECT 1")
      [false]
    rescue StandardError => e
      ["#{e.class}: #{e.message}"]
    end
    @postgres_error.first
  end

  before(:context) do
    skip "no local Postgres reachable (#{self.class.postgres_error})" if self.class.postgres_error

    conn = ::ActiveRecord::Base.connection
    conn.execute(%(DROP SCHEMA IF EXISTS "#{KYC_SPEC_SCHEMA}" CASCADE))
    conn.execute(%(CREATE SCHEMA "#{KYC_SPEC_SCHEMA}"))
    conn.execute(%(CREATE TABLE "#{KYC_SPEC_SCHEMA}".people (id text PRIMARY KEY)))
    conn.execute(%(INSERT INTO "#{KYC_SPEC_SCHEMA}".people VALUES ('u-1'), ('u-2')))
    conn.execute(%(SET search_path TO "#{KYC_SPEC_SCHEMA}", public))
    conn.execute(Kiosk::Server::SchemaDefinitions.kyc_attributes_sql(schema: KYC_SPEC_SCHEMA, user_id_type: :text,
                                                                     user_table: "people"))
  end

  after(:context) do
    next if self.class.postgres_error

    ::ActiveRecord::Base.connection.execute(%(RESET search_path; DROP SCHEMA IF EXISTS "#{KYC_SPEC_SCHEMA}" CASCADE))
  end

  let(:store)    { Kiosk::Server::EventStore.new }
  let(:kyc_key)  { OpenSSL::PKey::RSA.generate(2048) }
  let(:provider) { provider_class.new }

  # Answers the port and nothing else, so an engine that reached past it fails.
  let(:provider_class) do
    Class.new(Kiosk::KycProviders::Base) do
      attr_accessor :opened, :failing

      def open_verification(**args)
        raise Kiosk::KycProviders::Unavailable, "down" if failing

        self.opened = args
        id = "req-#{SecureRandom.hex(4)}"
        { request_id: id, verification_url: "https://kyc.example/verify/#{id}", nonce: "nonce-#{id}" }
      end

      def accepts?(payload) = payload["operator"] == "shop"
    end
  end

  def configure(kyc_provider)
    Kiosk.configure do |c|
      c.schema         = KYC_SPEC_SCHEMA
      c.signing_key    = Kiosk::Server::SigningKey.generate
      c.issuer         = "https://shop.example"
      c.roles          = %i[customer]
      c.agent_idp      = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
      c.event_store    = store
      c.kyc_provider   = kyc_provider
      c.kyc_claims     = %w[age_over_18 licence_a]
      c.kyc_issuer     = "https://kyc.example"
      c.kyc_audience   = "shop"
      c.kyc_public_key = kyc_key.public_key
    end
    Kiosk::Server::HandlerRegistrations.reload!([])
  end

  before do
    connection = ::ActiveRecord::Base.connection
    connection.execute(%(TRUNCATE "#{KYC_SPEC_SCHEMA}".kyc_attributes, "#{KYC_SPEC_SCHEMA}".kyc_requests))
    allow_any_instance_of(Kiosk::Server::VerbController)
      .to receive(:connection_for).and_return(FakeConnection.new)
  end

  def token(user_id: "u-1", agent_id: "a-1")
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: user_id, agent_id: agent_id, role: "customer", actor: "agent" },
      audience: "https://shop.example",
    )
  end

  def dispatch(controller, env)
    status, _headers, body = controller.action(:create).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, JSON.parse(raw)]
  end

  def request_kyc(user_id: "u-1")
    env = Rack::MockRequest.env_for(
      "/kiosk/request_kyc", method: "POST", input: "{}",
      "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token(user_id: user_id)}",
    )
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/verb", action: "create", kiosk_verb: "request_kyc" }
    dispatch(Kiosk::Server::VerbController, env)
  end

  def callback(body)
    env = Rack::MockRequest.env_for("/kiosk/kyc/callback", method: "POST", input: JSON.generate(body),
                                                           "CONTENT_TYPE" => "application/json")
    env["action_dispatch.request.path_parameters"] = { controller: "kiosk/server/kyc_callback", action: "create" }
    dispatch(Kiosk::Server::KycCallbackController, env)
  end

  def attestation(sub: "u-1", operator: "shop", attributes: { age_over_18: true, licence_a: true })
    now = Time.now.to_i
    JWT.encode({ sub: sub, level: "verified", iss: "https://kyc.example", aud: "shop", operator: operator,
                 iat: now, exp: now + 600, attributes: attributes }, kyc_key, "RS256")
  end

  def open_request(age: 0, user_id: "u-1")
    id = "old-#{SecureRandom.hex(4)}"
    ::ActiveRecord::Base.connection.exec_query(
      %(INSERT INTO "#{KYC_SPEC_SCHEMA}".kyc_requests (id, user_id, nonce, created_at) ) +
        %(VALUES ($1, $2, 'n', now() - make_interval(secs => $3))),
      "spec", [id, user_id, age],
    )
    id
  end

  def as(user_id, agent_id)
    Kiosk::Server::CurrentRequest.with(identity: build_identity(user_id: user_id, agent_id: agent_id)) { yield }
  end

  def granted(user_id = "u-1")
    ::ActiveRecord::Base.connection.exec_query(
      %(SELECT name FROM "#{KYC_SPEC_SCHEMA}".kyc_attributes WHERE user_id = $1 ORDER BY name), "spec", [user_id],
    ).to_a.map { |row| row.fetch("name") }
  end

  describe "an origin with no KYC provider" do
    before { configure(nil) }

    it "publishes neither request_kyc nor its topic" do
      expect(Kiosk::Server::Actions.known).not_to include("request_kyc")
      expect(Kiosk::Server::Events.known).not_to include("kyc_verification")
    end

    it "answers request_kyc and the callback with 501 module_not_served" do
      expect(request_kyc.first).to eq(501)
      status, problem = callback(request_id: "r", nonce: "n", kyc_jws: "x")
      expect([status, problem["code"]]).to eq([501, "module_not_served"])
    end

    it "gates naming agents/kyc and not request_kyc" do
      expect { as("u-1", "a-1") { described_class.require! } }
        .to raise_error(Kiosk::Server::Errors::KycRequired) { |e|
          expect(e.hint).to include("agents/kyc")
          expect(e.hint).not_to include("request_kyc")
        }
    end

    it "gates naming no KYC path when no kyc_public_key is configured either" do
      Kiosk.configuration.kyc_public_key = nil
      expect { as("u-1", "a-1") { described_class.require! } }
        .to raise_error(Kiosk::Server::Errors::KycRequired) { |e|
          expect(e.hint).not_to include("agents/kyc")
          expect(e.hint).not_to include("request_kyc")
          expect(e.hint).to include("not available at this origin")
        }
    end
  end

  describe "request_kyc" do
    before { configure(provider) }

    it "opens a verification of the declared claims for the principal" do
      status, body = request_kyc

      expect(status).to eq(200)
      expect(body).to include("status" => "pending", "verification_url" => start_with("https://kyc.example/verify/"))
      expect(provider.opened).to eq(subject: "u-1", claims: %w[age_over_18 licence_a], audience: "shop",
                                    callback_url: "https://shop.example/kiosk/kyc/callback")
    end

    it "names the claims in its descriptor and publishes the topic" do
      expect(Kiosk::Server::Actions.describe("request_kyc")[:description]).to include("age_over_18, licence_a")
      expect(Kiosk::Server::Events.known).to include("kyc_verification")
    end

    it "refuses a fourth open verification with 429 quota_exceeded" do
      3.times { open_request }
      status, problem = request_kyc
      expect([status, problem["code"]]).to eq([429, "quota_exceeded"])
      expect(provider.opened).to be_nil
    end

    it "stops counting a verification after the window, or once approved, or another person's" do
      2.times { open_request(age: described_class::OPEN_WINDOW + 60) }
      ::ActiveRecord::Base.connection.execute(
        %(UPDATE "#{KYC_SPEC_SCHEMA}".kyc_requests SET approved_at = now() WHERE id = '#{open_request}'),
      )
      open_request(user_id: "u-2")
      open_request
      open_request

      expect(request_kyc.first).to eq(200)
    end

    it "answers 500 action_failed when the provider does not open one" do
      provider.failing = true
      status, problem = request_kyc
      expect([status, problem["code"]]).to eq([500, "action_failed"])
    end
  end

  describe "the provider's callback" do
    before { configure(provider) }

    let!(:opened) { request_kyc.last }
    let(:request_id) { opened.fetch("request_id") }
    let(:nonce) { "nonce-#{request_id}" }

    it "records the grant on the person and pushes the attestation to them" do
      jws = attestation
      expect(callback(request_id: request_id, nonce: nonce, kyc_jws: jws)).to eq([200, { "ok" => true }])

      expect(granted).to eq(%w[age_over_18 licence_a])
      event = store.since("u-1", 0).first
      expect(event).to include("topic" => "kyc_verification", "subject" => request_id,
                               "data" => { "request_id" => request_id, "status" => "approved", "kyc_jws" => jws })
    end

    it "is good once: the same callback again finds no open verification" do
      callback(request_id: request_id, nonce: nonce, kyc_jws: attestation)
      expect(callback(request_id: request_id, nonce: nonce, kyc_jws: attestation).first).to eq(404)
    end

    it "refuses a wrong nonce, another subject, and an attestation the provider does not accept" do
      expect(callback(request_id: request_id, nonce: "wrong", kyc_jws: attestation).first).to eq(403)
      expect(callback(request_id: request_id, nonce: nonce, kyc_jws: attestation(sub: "u-2")).first).to eq(403)
      expect(callback(request_id: request_id, nonce: nonce, kyc_jws: attestation(operator: "other")).first).to eq(403)
      expect(granted).to eq([])
      expect(store.head).to eq(0)
    end

    it "names the open verification's principal when the subject is wrong" do
      _status, problem = callback(request_id: request_id, nonce: nonce, kyc_jws: attestation(sub: "u-2"))
      expect(problem["hint"]).to include("the open verification's at the callback")
    end

    it "answers 404 for a request_id it never opened" do
      expect(callback(request_id: "nope", nonce: nonce, kyc_jws: attestation).first).to eq(404)
    end

    it "answers 400 bad_request when request_id or kyc_jws is missing" do
      [{ nonce: nonce, kyc_jws: attestation }, { request_id: request_id, nonce: nonce }].each do |body|
        status, problem = callback(body)
        expect([status, problem["code"]]).to eq([400, "bad_request"])
      end
      expect(store.head).to eq(0)
    end
  end

  describe ".grant! and .require!" do
    before { configure(provider) }

    it "grants only the JSON boolean true, in Postgres" do
      described_class.grant!("u-1", "age_over_18" => true, "licence_a" => "true", "adult" => 1, "x" => false)
      expect(granted).to eq(%w[age_over_18])
    end

    it "replaces the grant set" do
      described_class.grant!("u-1", "age_over_18" => true, "licence_a" => true)
      described_class.grant!("u-1", {})
      expect(granted).to eq([])
    end

    it "refuses with kyc_required until the person holds every declared claim" do
      described_class.grant!("u-1", "age_over_18" => true)
      expect { as("u-1", "a-1") { described_class.require! } }
        .to raise_error(Kiosk::Server::Errors::KycRequired, /age_over_18, licence_a/) { |e|
          expect(e.hint).to include("request_kyc")
        }
    end

    it "lets every assistant of that person through, and nobody else" do
      described_class.grant!("u-1", "age_over_18" => true, "licence_a" => true)
      expect { as("u-1", "a-2") { described_class.require! } }.not_to raise_error
      expect { as("u-2", "a-1") { described_class.require! } }.to raise_error(Kiosk::Server::Errors::KycRequired)
    end
  end
end
