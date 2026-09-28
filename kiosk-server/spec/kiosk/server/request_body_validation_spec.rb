# frozen_string_literal: true

# RESERVED-PLANE BODY VALIDATION (T-045).
#
# Every JSON request body the reserved plane accepts is held to the object
# Section 17 of the spec publishes for it, from the vendored copy
# `bin/check-spec-schemas` keeps equal to the published original. The refusal
# is `400 bad_request` naming the member that failed, which is what an
# assistant needs to correct a call it has not been able to authenticate yet.
#
# The two `/oauth/*` requests are absent on purpose: Section 17 says they are
# form-encoded and publishes no schema for them.
#
# One accepted body and one refused body per exchange, then the refusal SHAPE
# over HTTP, then the two arms that keep the table honest — the flag really
# switches it off, and no endpoint dials an exchange the table does not carry.

require "rack/mock"
require "json"

RSpec.describe "Reserved-plane request-body validation" do
  RV = Kiosk::Server::RequestValidation

  # An accepted body per exchange, spelled out rather than derived: these are
  # the bodies the spec's own example payloads carry, and a reader comparing
  # this file with `spec/schemas/examples/` should see the same members.
  ACCEPTED = {
    "POST <endpoint>/auth/register" => { public_key: "-----BEGIN PUBLIC KEY-----\nMII\n-----END PUBLIC KEY-----\n",
                                         signed: "eyJ.eyJ.SIG" },
    "POST <endpoint>/auth/login"    => { public_key: "-----BEGIN PUBLIC KEY-----\nMII\n-----END PUBLIC KEY-----\n",
                                         signed: "eyJ.eyJ.SIG" },
    "POST <endpoint>/auth/claim"    => { code: "ABCD-1234", public_key: "-----BEGIN PUBLIC KEY-----\nMII\n-----END PUBLIC KEY-----\n",
                                         signed: "eyJ.eyJ.SIG" },
    "POST <endpoint>/auth/unlink"   => { agent_id: "a-1" },
    "POST <endpoint>/agents/kyc"    => { kyc_jws: "eyJ.eyJ.SIG" },
    "POST <endpoint>/pay"           => { intent_mandate_jws: "eyJ.eyJ.SIG",
                                         cart_mandate_jws: "eyJ.eyJ.SIG",
                                         payment_mandate_jws: "eyJ.eyJ.SIG" },
  }.freeze

  # The member each refused body gets wrong, and how. A wrong TYPE rather than
  # an absent member: an absent one was already a 400 from the `fetch` beside
  # the call site, and the type is the half nothing read.
  WRONG_TYPE = {
    "POST <endpoint>/auth/register" => :public_key,
    "POST <endpoint>/auth/login"    => :signed,
    "POST <endpoint>/auth/claim"    => :code,
    "POST <endpoint>/auth/unlink"   => :agent_id,
    "POST <endpoint>/agents/kyc"    => :kyc_jws,
    "POST <endpoint>/pay"           => :cart_mandate_jws,
  }.freeze

  before do
    RV.reset!
    Kiosk.configure { |c| c.validate_requests = true }
  end

  RV::BODY_SCHEMAS.each_key do |exchange|
    context exchange do
      it "accepts a body that satisfies the published object" do
        expect { RV.validate_body!(ACCEPTED.fetch(exchange), exchange: exchange) }
          .not_to raise_error
      end

      it "refuses a wrong-typed member, naming it" do
        member = WRONG_TYPE.fetch(exchange)
        body   = ACCEPTED.fetch(exchange).merge(member => 42)

        expect { RV.validate_body!(body, exchange: exchange) }
          .to raise_error(Kiosk::Server::Errors::BadRequest, /#{member}/)
      end

      it "refuses an absent required member, naming it" do
        member = WRONG_TYPE.fetch(exchange)
        body   = ACCEPTED.fetch(exchange).reject { |name, _| name == member }

        expect { RV.validate_body!(body, exchange: exchange) }
          .to raise_error(Kiosk::Server::Errors::BadRequest, /#{member}/)
      end
    end
  end

  # NON-VACUITY. Section 16.3 anchor 1 makes validating a SHOULD, so an
  # operator may turn it off — and an example that never exercised the off
  # position would not know whether the flag reaches this layer at all.
  it "does nothing when the operator sets validate_requests = false" do
    Kiosk.configure { |c| c.validate_requests = false }

    expect { RV.validate_body!({ public_key: 42 }, exchange: "POST <endpoint>/auth/register") }
      .not_to raise_error
  end

  describe "the refusal, over HTTP" do
    def dispatch(controller, action, env)
      status, headers, body = controller.action(action).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }
      [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
    end

    before do
      Kiosk.configure do |c|
        c.signing_key = Kiosk::Server::SigningKey.generate
        c.issuer      = "https://demo.example"
      end
    end

    it "is an RFC 9457 bad_request naming the member and pointing at the schema" do
      env = Rack::MockRequest.env_for(
        "/kiosk/auth/register",
        method: "POST", input: JSON.generate(public_key: 42, signed: "eyJ.eyJ.SIG"),
        "CONTENT_TYPE" => "application/json",
      )
      status, headers, body = dispatch(Kiosk::Server::AuthController, :register, env)

      expect(status).to eq(400)
      expect(headers["Content-Type"]).to include("application/problem+json")
      expect(body[:code]).to eq("bad_request")
      expect(body[:detail]).to include("auth/register").and include("public_key")
      expect(body[:hint]).to include("auth.schema.json")
    end
  end

  # THE TABLE IS THE LIST, so nothing may dial an exchange it does not carry.
  # Derived from the engine's own source rather than restated here: a seventh
  # endpoint wired up without a row fails this example instead of raising
  # KeyError at a caller.
  it "carries every exchange the engine dials" do
    lib    = File.expand_path("../../../lib", __dir__)
    dialed = Dir[File.join(lib, "**", "*.rb")].flat_map do |path|
      File.read(path).scan(/exchange:\s*"([^"]+)"|parse_body!\("([^"]+)"\)/).flatten.compact
    end.uniq

    expect(dialed).not_to be_empty
    expect(dialed - RV::BODY_SCHEMAS.keys).to eq([])
  end
end
