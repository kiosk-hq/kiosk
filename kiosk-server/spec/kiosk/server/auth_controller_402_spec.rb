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
# Like wire_controller_402_spec.rb: re-`load` the controller and dispatch through
# ActionController::Metal.action.

require "action_controller"
require "rack/mock"
require "json"
require "kiosk/pow/equihash"
require "kiosk/reputation"

load File.expand_path("../../../lib/kiosk/server/auth_controller.rb", __dir__)

RSpec.describe "AuthController 402 WWW-Authenticate" do
  KAT_PARAMS_314 = { n: 8, k: 1 }.freeze
  PEM_314 = "-----BEGIN PUBLIC KEY-----\nMFkwE... (test)\n-----END PUBLIC KEY-----"

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
      c.registration_pow_params = KAT_PARAMS_314
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
      input: JSON.generate(public_key: PEM_314, signed: "dummy-not-reached"),
    )
    status, headers, body = dispatch(:register, env)

    expect(status).to eq(402)
    expect(headers["WWW-Authenticate"]).to eq('Kiosk-PoW realm="https://demo.example"')
    expect(body.dig(:error, :code)).to eq("pow_required")
    expect(body.dig(:error, :challenges)).to be_an(Array)
    expect(body.dig(:error, :challenges)).not_to be_empty
  end
end
