# frozen_string_literal: true

require "base64"
require "json"
require "jwt"
require "openssl"
require "securerandom"
require "uri"

require "kiosk/user_identity_providers/devise_session"
require_relative "equihash_register"

# An agent principal bound to a seeded human, earned over the shipped ceremony:
# Equihash-tolled register, the human's Devise sign-in and link code, then claim.
BoundAssistant = Struct.new(:agent_id, :user_id, :token, keyword_init: true) do
  # The header an agent's call carries — and the only thing it carries.
  def bearer = { "Authorization" => "Bearer #{token}" }

  # Claims of the currently held token, for drivers that assert on them.
  def claims
    seg = token.split(".")[1]
    JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
  end
end

def bind_assistant(server:, issuer:, email:, password:)
  session = Kiosk::UserIdentityProviders::DeviseSession.new(server)

  # The register handshake carries no cookies and speaks full URLs; the session speaks paths.
  get_url  = ->(url) { session.get_json(url.delete_prefix(server)) }
  post_url = ->(url, body, headers = {}) { session.post_json(url.delete_prefix(server), body, headers) }
  key, = equihash_register(server: server, issuer: issuer, get_json: get_url, post_json: post_url)
  pem = key.public_key.to_pem

  session.sign_in!(email: email, password: password)

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
    token: claimed.fetch("access_token"),
  )
end
