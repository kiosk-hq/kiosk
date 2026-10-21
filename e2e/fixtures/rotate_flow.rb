# frozen_string_literal: true

# Key rotation over the wire (spec Section 5.7). A newly registered agent puts a
# new key on its identity: each key signs a challenge issued for it, and the old
# key's proof names the new key by its RFC 7638 thumbprint. Emits ONE JSON line
# for assistant.sh to assert on.
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

# A possession proof of `key` over a fresh challenge issued for it; `claims` adds members.
def proof(key, claims = {})
  pem = URI.encode_www_form_component(key.public_key.to_pem)
  rc, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{pem}")
  abort "challenge failed: #{rc} #{ch}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch('challenge'), jti: SecureRandom.uuid }.merge(claims), key, 'RS256')
end

def claims_of(token)
  seg = token.split('.')[1].to_s
  JSON.parse(Base64.urlsafe_decode64(seg + ('=' * ((4 - (seg.length % 4)) % 4))))
end

def salons_status(token, key) = get_json(SALONS, Kiosk::TestHelpers::Dpop.headers(token, key, method: 'GET', url: SALONS)).first

require_relative 'equihash_register'
old_key, reg = equihash_register(server: SERVER, issuer: ISSUER)
old_token = reg.fetch('access_token')
new_key = OpenSSL::PKey::RSA.generate(2048)
results = { old_token_before: salons_status(old_token, old_key) }

rotate = lambda do |signed_by_old|
  post_json("#{SERVER}/kiosk/auth/rotate",
            { public_key: old_key.public_key.to_pem, signed: signed_by_old,
              new_public_key: new_key.public_key.to_pem, new_signed: proof(new_key) })
end

# The old key's proof must name the new key: one that names no key is refused,
# and nothing moves.
rc, = rotate.call(proof(old_key))
results[:unnamed_new_key] = rc
results[:old_token_after_refusal] = salons_status(old_token, old_key)

rc, rotated = rotate.call(proof(old_key, new_key: Kiosk::TestHelpers::Dpop.thumbprint(new_key)))
results[:rotate] = rc
new_token = rotated.fetch('access_token', '')
results[:same_agent] = claims_of(new_token)['agent_id'] == reg.fetch('agent_id')
results[:same_user]  = claims_of(new_token)['sub'] == reg.fetch('user_id')
results[:bound_to_new_key] = claims_of(new_token).dig('cnf', 'jkt') == Kiosk::TestHelpers::Dpop.thumbprint(new_key)
results[:new_token] = salons_status(new_token, new_key)
results[:new_token_old_key_proof] = salons_status(new_token, old_key)
results[:old_token_after] = salons_status(old_token, old_key)
rc, = post_json("#{SERVER}/kiosk/auth/login", { public_key: old_key.public_key.to_pem, signed: proof(old_key) })
results[:old_key_login] = rc
rc, = post_json("#{SERVER}/kiosk/auth/login", { public_key: new_key.public_key.to_pem, signed: proof(new_key) })
results[:new_key_login] = rc

puts JSON.generate(results)
