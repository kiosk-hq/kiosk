# frozen_string_literal: true

require "base64"
require "json"
require "jwt"
require "openssl"
require "securerandom"
require "uri"

require_relative "devise_session"
require_relative "equihash_register"

# The ONE way a demo driver obtains an AGENT principal bound to a seeded human.
#
# This is the agent-side twin of lib/devise_session.rb, and it exists for the
# same reason (T-104, from K-660). Drivers used to hand themselves a principal
# by writing one down — `agent:u-<uuid>:a-<uuid>:r-customer` — which a dev-only
# parser in the demo turned into an authenticated identity at any role. That
# parser is gone; agent auth now runs through the engine's own kiosk-pop JWTs,
# the ones `/kiosk/auth/register` and `/kiosk/auth/claim` mint, verified by the
# `DefaultAgentIdp` kiosk-server has always shipped as the default.
#
# So a driver that needs "an assistant acting for Alice" has to EARN one, the
# way a real assistant does:
#
#   1. register a fresh RSA key through the Equihash-tolled `/auth/register`
#      — which mints a HEADLESS account, not Alice's;
#   2. sign Alice in through the real Devise form and mint a link code on her
#      session (`POST /auth/link`);
#   3. redeem it with the same key (`POST /auth/claim`) — a REBIND: the
#      agent_id is stable, the principal becomes Alice, and the response
#      carries the access token that says so.
#
# That is the whole ceremony, over real HTTP, with no shortcut anywhere in it.
# It costs about a quarter-second of Equihash at the demos' shipped parameters,
# which is the price of a driver whose principal is one the shipped code issued
# rather than one the driver asserted.
#
#   alice = bind_assistant(server: SERVER, issuer: ISSUER,
#                          email: "alice@example.com", password: PASSWORD)
#   get_json("/kiosk/my_listings", {}, alice.bearer)
#
# `agent_id` is a UUID here because `/auth/register` minted it (K-829/K-830):
# every `agent_id` column in the canonical schema is typed `uuid`, and a driver
# can no longer choose a shape the tables cannot store.
BoundAssistant = Struct.new(:agent_id, :user_id, :token, :key, :pem, :session,
                            keyword_init: true) do
  # The header an agent's call carries — and the only thing it carries. The
  # human's cookie jar lives on `session` and never travels with these.
  def bearer = { "Authorization" => "Bearer #{token}" }

  # Claims of the currently held token, for drivers that assert on them.
  def claims
    seg = token.split(".")[1]
    JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
  end

  # A fresh possession proof for this key — `/auth/login`, a second claim, or
  # any beat that needs to re-prove the key.
  def pop_proof(issuer)
    rc, ch = session.get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
    raise "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200

    JWT.encode({ aud: issuer, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
               key, "RS256")
  end
end

# Run the full register -> link -> claim ceremony and return a {BoundAssistant}.
#
# @param server [String] base URL of the booted demo
# @param issuer [String] issuer origin for the possession proof's `aud` claim
# @param email [String] a SEEDED human's Devise email
# @param password [String] that human's password (db/seeds.rb)
# @param session [DeviseSession, nil] reuse an existing human session; a fresh
#   one is signed in when omitted. Two assistants for the SAME human should
#   share one session — two humans must never share one.
# @return [BoundAssistant]
def bind_assistant(server:, issuer:, email:, password:, session: nil)
  fresh_session = session.nil?
  session ||= DeviseSession.new(server)

  # 1. Headless registration. These calls carry no cookies (no `session: true`)
  #    — an assistant's handshake is its own, and the jar is opt-in per request.
  #    The register handshake speaks full URLs; DeviseSession speaks paths.
  get_url  = ->(url) { session.get_json(url.delete_prefix(server)) }
  post_url = ->(url, body, headers = {}) { session.post_json(url.delete_prefix(server), body, headers) }
  key, = equihash_register(server: server, issuer: issuer, get_json: get_url, post_json: post_url)
  pem = key.public_key.to_pem

  # 2. The human, for real, on the shipped Devise form.
  session.sign_in!(email: email, password: password) if fresh_session

  # 3. Link code on the human's session, redeemed by the key from step 1.
  rc, link = session.post_json("/kiosk/auth/link", {}, { session: true })
  raise "link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201

  rc, ch = session.get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  raise "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200

  signed = JWT.encode(
    { aud: issuer, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
    key, "RS256",
  )
  rc, claimed = session.post_json("/kiosk/auth/claim",
                                  { code: link.fetch("link_code"), public_key: pem, signed: signed })
  raise "claim failed (#{rc}): #{JSON.generate(claimed)}" unless rc == 201

  BoundAssistant.new(
    agent_id: claimed.fetch("agent_id"), user_id: claimed.fetch("user_id"),
    token: claimed.fetch("access_token"), key: key, pem: pem, session: session,
  )
end
