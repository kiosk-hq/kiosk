# frozen_string_literal: true

# Key rotation over the wire (spec Section 5.7). A newly registered client puts a
# new key on its identity: each key signs a client assertion, and the old key's
# assertion names the new key by its RFC 7638 thumbprint. The token endpoint
# then issues a token for the new key only. Emits ONE JSON line for
# assistant.sh to assert on.
#
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby rotate_flow.rb
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
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

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

def claims_of(token)
  seg = token.split('.')[1].to_s
  JSON.parse(Base64.urlsafe_decode64(seg + ('=' * ((4 - (seg.length % 4)) % 4))))
end

def salons_status(token, key) = get_json(SALONS, Kiosk::TestHelpers::Dpop.headers(token, key, method: 'GET', url: SALONS)).first

require_relative 'equihash_register'
old_key, reg, old_token = register_with_token(server: SERVER, issuer: ISSUER)
client_id = reg.fetch('client_id')
new_key = OpenSSL::PKey::RSA.generate(2048)
results = { old_token_before: salons_status(old_token, old_key) }

rotate = lambda do |old_assertion|
  post_json("#{SERVER}/kiosk/auth/rotate",
            { client_assertion_type: ASSERTION_TYPE, client_assertion: old_assertion,
              new_client_assertion: client_assertion(client_id, new_key, ISSUER),
              jwks: { keys: [Kiosk::TestHelpers::Dpop.jwk(new_key)] } })
end

# The old key's assertion must name the new key: one that names no key is
# refused, and nothing moves.
rc, = rotate.call(client_assertion(client_id, old_key, ISSUER))
results[:unnamed_new_key] = rc
results[:old_token_after_refusal] = salons_status(old_token, old_key)

rc, rotated = rotate.call(client_assertion(client_id, old_key, ISSUER, new_key: Kiosk::TestHelpers::Dpop.thumbprint(new_key)))
results[:rotate] = rc
results[:same_agent] = rotated['client_id'] == client_id
rc, tok = client_token(server: SERVER, issuer: ISSUER, client_id:, key: new_key)
results[:new_key_token] = rc
new_token = tok.fetch('access_token', '')
results[:same_user] = claims_of(new_token)['sub'] == claims_of(old_token)['sub']
results[:bound_to_new_key] = claims_of(new_token).dig('cnf', 'jkt') == Kiosk::TestHelpers::Dpop.thumbprint(new_key)
results[:new_token] = salons_status(new_token, new_key)
results[:new_token_old_key_proof] = salons_status(new_token, old_key)
results[:old_token_after] = salons_status(old_token, old_key)
rc, = client_token(server: SERVER, issuer: ISSUER, client_id:, key: old_key)
results[:old_key_token] = rc

puts JSON.generate(results)
