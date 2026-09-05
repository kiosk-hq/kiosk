# frozen_string_literal: true

# Mint ONE agent bearer for a shell driver, over the real wire.
#
# bin/demo is a curl tour, and there is no bearer a shell script can simply
# write down. The engine's own `DefaultAgentIdp` verifies kiosk-pop JWTs and
# nothing else — a self-asserted `agent:u-…:a-…:r-…` string resolves to no
# identity at all — so a token has to be EARNED at
# `/kiosk/auth/register`: an RSA keypair, a signed possession proof, and
# whatever Equihash the operator tolls the handshake with. None of that is
# curl-shaped, so the tour shells out here ONCE and carries the result in its
# Authorization header for the rest of the walk.
#
# This is the HEADLESS half of the fleet's two principals: registration mints
# the assistant its own account row, so the tour needs no seeded human and no
# password. The other half — a human diner linking an assistant to THEIR account
# — is `rake demo:binding`, and script/bound_assistant.rb is how a driver runs it.
#
# Prints the access token on stdout and NOTHING else, so `$( )` captures a
# usable header value; aborts non-zero with the server's own answer when the
# handshake fails.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby script/mint_agent_token.rb

require "json"
require "jwt"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

require_relative "equihash_register"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url)
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)

puts reg.fetch("access_token")
