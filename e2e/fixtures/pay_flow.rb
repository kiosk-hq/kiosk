# frozen_string_literal: true

# No-human payment proof. The agent generates its own keypair, SELF-REGISTERS
# a synthetic principal (no human, no device-grant), sets up payment, signs the
# two closed AP2 mandates for a checkout the operator signed for that
# principal, and pays. Prints a JSON line on stdout.
require 'base64'
require 'fileutils'
require 'jwt'
require 'json'
require 'net/http'
require 'kiosk/test_helpers/dpop'
require 'kiosk/test_helpers/mandate'
require 'kiosk/test_helpers/wire'
require 'uri'
require 'openssl'
require 'securerandom'

SERVER = ENV.fetch('SERVER_URL')
ISSUER = ENV.fetch('KIOSK_ISSUER')

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { 'Content-Type' => 'application/json' }.merge(headers))
  req.body = JSON.generate(body)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

# Register the key (RFC 7591), then get a token from the token endpoint with a
# client assertion and a DPoP proof. `aud` binds the assertion to this origin so
# it can't be relayed. Registration has an Equihash toll
# (registration_pow_count=1); register_with_token pays the toll and returns the
# keypair, the 201 client information and the token.
require_relative 'equihash_register'
key, reg, token = register_with_token(server: SERVER, issuer: ISSUER)
agent_id = reg.fetch('client_id')
user_id = JWT.decode(token, nil, false).first.fetch('sub')
# A POST that carries the token also carries a proof that the key signs for its URL (RFC 9449).
auth = ->(url) { Kiosk::TestHelpers::Dpop.headers(token, key, method: 'POST', url: url) }

# payment_setup maps a Stripe Customer and hands over the setup page. stripe-mock
# lists a saved card for that Customer, so the second answer is ready.
setup_url = "#{SERVER}/kiosk/payment_setup"
setup = Array.new(2) { post_json(setup_url, {}, auth.call(setup_url)).last }

# The e2e origin has no action that answers a checkout, so the harness signs one
# here as the operator does: EdDSA with the operator's key, naming its kid, with
# a random jti.
operator_key = OpenSSL::PKey.read(Base64.decode64(ENV.fetch('KIOSK_SIGNING_KEY_B64')))
kid = Kiosk::TestHelpers::Dpop.thumbprint(operator_key) # RFC 7638
checkout = { iss: ISSUER, sub: user_id, iat: Time.now.to_i, jti: SecureRandom.urlsafe_base64(16),
             merchant: { id: ISSUER, name: 'Combette E2E Demo', website: ISSUER },
             currency: 'eur', total_amount_cents: 1599,
             line_items: [{ order_id: '0b9e6f1c-3d2a-4e5b-8c7d-9a0f1e2d3c4b' }, { sku: 'pizza', qty: 1, price_cents: 1599 }] }
checkout_jwt = JWT.encode(checkout, operator_key, 'EdDSA', { kid:, typ: 'JWT' })

mandates    = Kiosk::TestHelpers::Mandate.pay(key, checkout_jwt, instrument: 'pm_demo')
pay_request = { checkout_mandate: mandates[:checkout], payment_mandate: mandates[:payment] }

pay_url = "#{SERVER}/kiosk/pay"
rc, pay = post_json(pay_url, pay_request, auth.call(pay_url))

# The two AP2 receipts, verified as an assistant verifies them: against the key
# of the JWKS the origin serves that the kid names, EdDSA. Each names the
# mandate it answers by reference.
_, jwks = get_json("#{SERVER}/kiosk/.well-known/jwks.json")
jwk_for = ->(header) { Kiosk::Server::Jwk.import(jwks.fetch('keys').find { it['kid'] == header['kid'] }) }
receipt = ->(name) { JWT.decode(pay.fetch(name), nil, true, algorithms: ['EdDSA'], &jwk_for).first }
receipts = rc == 200 ? { checkout: receipt.call('checkout_receipt'), payment: receipt.call('payment_receipt') } : {}
references = mandates.transform_values { Kiosk::TestHelpers::Mandate.digest(it) }

# The skill's file rule: each payment in its own file in the origin directory,
# the pay answer and the two mandates, named so the files sort by time.
if rc == 200
  path = File.join(ENV.fetch('PAYER_DIR'), 'receipts',
                   "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{receipts[:payment].fetch('payment_id')}.json")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate(response: pay, **pay_request))
  File.chmod(0o600, path)
end

# THE BYTES, KEPT. `PAY_CAPTURE` names a file to write the request this
# origin ACCEPTED, the checkout and the two mandates inside it, and the
# settlement it answered with its two receipts — so `e2e/schema_conformance.rb` can validate all seven
# against the published `mandates.schema.json` rather than against a
# hand-written example. Nothing is reconstructed here: these are the same
# objects the request carried.
if (capture = ENV.fetch('PAY_CAPTURE', nil))
  File.write(capture, JSON.generate(
                        request: pay_request,
                        claims: { checkout: checkout,
                                  checkout_mandate: Kiosk::TestHelpers::Mandate.content(mandates[:checkout]),
                                  payment_mandate: Kiosk::TestHelpers::Mandate.content(mandates[:payment]),
                                  checkout_receipt: receipts[:checkout], payment_receipt: receipts[:payment] },
                        response: pay
                      ))
end

puts JSON.generate(http_code: rc, user_id: user_id, agent_id: agent_id, setup: setup, response: pay, receipts:, references:)
