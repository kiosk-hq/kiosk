# frozen_string_literal: true

# The algorithms of an assistant key (spec Section 5.1). This origin accepts
# ES256 beside EdDSA, so a P-256 key registers, gets a token bound to it and
# calls with ES256 DPoP proofs. An RSA key is refused at registration. Emits
# ONE JSON line for assistant.sh to assert on.
#
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby es256_flow.rb
require 'jwt'
require 'json'
require 'net/http'
require 'kiosk/test_helpers/dpop'
require 'kiosk/test_helpers/wire'
require 'uri'
require 'openssl'
require 'securerandom'
require 'base64'

SERVER = ENV.fetch('SERVER_URL')
ISSUER = ENV.fetch('KIOSK_ISSUER')
SALONS = "#{SERVER}/kiosk/salons".freeze

def get_json(url, headers = {})
  uri = URI(url)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, JSON.parse(res.body)]
end

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { 'Content-Type' => 'application/json' }.merge(headers))
  req.body = JSON.generate(body)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, JSON.parse(res.body)]
end

# The JSON of one base64url segment of a JWT.
def decoded(segment) = JSON.parse(Base64.urlsafe_decode64(segment + ('=' * (-segment.length % 4))))

require_relative 'equihash_register'
p256 = Kiosk::TestHelpers::Dpop.generate_key('ES256')
_, reg, token = register_with_token(server: SERVER, issuer: ISSUER, key: p256)
proof = Kiosk::TestHelpers::Dpop.proof(token, p256, method: 'GET', url: SALONS)
claims = decoded(token.split('.')[1])

rsa = OpenSSL::PKey::RSA.generate(2048)
b64 = ->(n) { Base64.urlsafe_encode64(n.to_s(2), padding: false) }
rc_rsa, rsa_answer = post_json("#{SERVER}/kiosk/oauth/register", { jwks: { keys: [{ kty: 'RSA', n: b64.call(rsa.n), e: b64.call(rsa.e) }] } })

puts JSON.generate(
  registered_kty: reg.dig('jwks', 'keys', 0, 'kty'),
  proof_alg: decoded(proof.split('.').first)['alg'],
  bound_to_key: claims.dig('cnf', 'jkt') == Kiosk::TestHelpers::Dpop.thumbprint(p256),
  salons: get_json(SALONS, Kiosk::TestHelpers::Dpop.headers(token, p256, method: 'GET', url: SALONS)).first,
  rsa_register: rc_rsa, rsa_error: rsa_answer['error']
)
