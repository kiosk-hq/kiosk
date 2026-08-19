# frozen_string_literal: true

# AuthController 402 WWW-Authenticate header spec.
#
# The registration toll answers `402 pow_required` at POST /kiosk/auth/register.
# The spec error table (specification.html) and skill both state every
# pow_required 402 carries `WWW-Authenticate: Kiosk-PoW`, so the register path
# must set the header too — not only the wire verbs (WireController). The toll
# (RegistrationPow.gate) runs BEFORE PoP verification, so a dummy `signed` still
# reaches the 402.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require "rack/mock"
require "json"
require "kiosk/pow/equihash"
require "kiosk/reputation"

RSpec.describe "AuthController 402 WWW-Authenticate" do
  KAT_PARAMS_REGISTER = { n: 8, k: 1 }.freeze
  PEM_REGISTER = "-----BEGIN PUBLIC KEY-----\nMFkwE... (test)\n-----END PUBLIC KEY-----"

  def dispatch(action, env)
    status, headers, body = Kiosk::Server::AuthController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  before do
    Kiosk::Reputation::Backends.register("equihash", Kiosk::Pow::Equihash)
    Kiosk.configure do |c|
      c.signing_key             = Kiosk::Server::SigningKey.generate
      c.issuer                  = "https://demo.example"
      c.registration_pow_count  = 1
      c.registration_pow_params = KAT_PARAMS_REGISTER
      c.pow_secret              = "registration-pow-secret"
    end
  end

  after do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end

  it "register toll 402 pow_required carries WWW-Authenticate: Kiosk-PoW AND the challenges body" do
    env = Rack::MockRequest.env_for(
      "/kiosk/auth/register", method: "POST", "CONTENT_TYPE" => "application/json",
      input: JSON.generate(public_key: PEM_REGISTER, signed: "dummy-not-reached"),
    )
    status, headers, body = dispatch(:register, env)

    expect(status).to eq(402)
    expect(headers["WWW-Authenticate"]).to eq('Kiosk-PoW realm="https://demo.example"')

    # The auth plane answers the SAME RFC 9457 problem document the wire does
    # (0.4 cutover): the media type is half of what makes it one, and the
    # closed-vocabulary token moved from `error.code` to the top level.
    expect(headers["Content-Type"]).to include("application/problem+json")
    expect(body[:type]).to   eq("https://kiosk.tech/problems/pow_required")
    expect(body[:title]).to  eq("Proof-of-work required")
    expect(body[:status]).to eq(402)
    expect(body[:code]).to   eq("pow_required")

    # `challenges` is an RFC 9457 EXTENSION MEMBER now — top level, no longer
    # nested under `error` — and still the full set the client must solve.
    expect(body[:challenges]).to be_an(Array)
    expect(body[:challenges]).not_to be_empty

    # The render seam applies the wire cache policy to the auth plane too, and
    # a 402 carries a challenge that is single-use and request-bound: caching
    # one either defeats the toll or loops the retry forever.
    expect(headers["Cache-Control"]).to eq("no-store")
    expect(headers["Vary"]).to eq("Authorization, Kiosk-PoW")
  end
end
