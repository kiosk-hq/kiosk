# frozen_string_literal: true

# roles-from-IdP driver (Path A) — the INDIRECT, human-idp path.
#
# A salon OWNER links their assistant (W5 link-code ceremony); the assistant
# INHERITS the human's role, sourced from the provider's own IdP at link time —
# never self-selected by the agent. kiosk-server captures that role onto the
# link row at mint and sets the bound agent's allowed_roles from it. The
# `salon_calendar` query then gates on kiosk.current_role():
#
#   OWNER    links an assistant → token role == owner    → salon_calendar returns
#            the WHOLE book (every visitor's booking) + a FORECAST € total.
#   CUSTOMER links an assistant → token role == customer → salon_calendar returns
#            ONLY that customer's own bookings, and NO forecast.
#
# (There is no stylist roster: the menu is evergreen and infinite-capacity, so
# the meaningful role contrast is owner=whole-book+forecast vs customer=own-only.)
#
# ONE channel, the real one (T-066). This flow used to run every beat twice —
# once through an `X-Staff-Session` SSO stand-in and once through Devise —
# because a role that only resolves through the stand-in is a role that does not
# work for a real operator (K-437, the bug Phil hit live where the owner's token
# came back `customer`). The stand-in is deleted, so there is nothing left to
# contrast: every principal here signs in through the real /users/sign_in form
# and mints the link over that Devise session cookie, and the role is resolved
# by Kiosk::UserIdentityProviders::Devise off the User model's `#kiosk_role`,
# which reads the provider's own `staff_role` column. That column, not a header,
# was always the role source.
#
# Prints ONE JSON line; non-zero exit on any hard failure.

require "date"
require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"
require "base64"

require_relative "../lib/devise_session"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# Seeded principals and their Devise credentials (db/seeds.rb). The owner
# carries staff_role='owner'; Alice carries none, which is what makes her a
# customer — the same table, the same form, two roles.
DEMO_PASSWORD  = "combette-demo-password"
OWNER_EMAIL    = "owner@combette.example"
CUSTOMER_EMAIL = "alice@example.com"

def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` carrying its arguments
# in the query string; there is no `name` field and no /query endpoint. A
# success body IS the result — `salon_calendar` answers a bare JSON array of
# rows, not `{"rows": …}`.
def get_json(path, headers = {}, params = {})
  uri = URI("#{SERVER}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  req = Net::HTTP::Get.new(uri, headers)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Fresh possession proof (same challenge-response JWS as register/link claim).
def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

def jwt_claims(token)
  seg = token.split(".")[1]
  JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
end

# Redeem a link code with a fresh key + possession proof, returning the minted
# token's claims. Shared by the stub and the real-Devise paths.
def claim_link(code, label)
  key = OpenSSL::PKey::RSA.generate(2048)
  pem = key.public_key.to_pem
  rc, claimed = post_json("/kiosk/auth/claim",
                          { code: code, public_key: pem, signed: pop_proof(key, pem) })
  abort "#{label}: claim failed (#{rc}): #{JSON.generate(claimed)}" unless rc == 201

  token  = claimed.fetch("access_token")
  claims = jwt_claims(token)
  STDERR.puts "  #{label}: linked assistant agent_id=#{claims["agent_id"]} role=#{claims["role"].inspect}"
  { token: token, claims: claims }
end

# Sign in through the real /users/sign_in form, then mint the link over that
# session cookie — so the role is resolved by
# Kiosk::UserIdentityProviders::Devise off the User model's #kiosk_role,
# exactly as a hosted-demo operator experiences it.
#
# One DeviseSession per call, so each principal is an independent browser.
def link_assistant_via_devise(email, password, label)
  session = DeviseSession.new(SERVER).sign_in!(email: email, password: password)
  rc, link = session.post_json("/kiosk/auth/link", {}, { session: true })
  abort "#{label}: link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201

  claim_link(link.fetch("link_code"), label)
end

results = {}

# ══ OWNER signs in for real → role owner → salon_calendar = whole book ══════
#    Without User#kiosk_role the Devise adapter falls back to roles.first
#    (customer), so the owner's token would come back "customer" and the
#    forecast would disappear — that is the K-437 regression these beats catch,
#    and since T-066 there is no second channel that could mask it.
owner = link_assistant_via_devise(OWNER_EMAIL, DEMO_PASSWORD, "OWNER")
results[:owner_token_role] = owner[:claims]["role"]
rc, cal = get_json("/kiosk/salon_calendar",
                   { "Authorization" => "Bearer #{owner[:token]}" })
abort "OWNER salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
owner_rows     = Array(cal)
owner_summary  = owner_rows.find { |r| r["summary"] == "forecast" }
owner_bookings = owner_rows.select { |r| r["kind"] == "booking" }
results[:owner_booking_count]   = owner_bookings.size
results[:owner_forecast_cents]  = owner_summary && owner_summary["forecast_cents"]
results[:owner_sees_forecast]   = !owner_summary.nil?
results[:devise_owner_token_role]   = results[:owner_token_role]
results[:devise_owner_sees_forecast] = results[:owner_sees_forecast]
STDERR.puts "  OWNER sees #{owner_bookings.size} bookings; forecast=#{results[:owner_forecast_cents]} cents"

# CUSTOMER through the same real Devise session → role customer, own bookings,
# no forecast. Same channel, different `staff_role` — that IS the role source.
d_customer = link_assistant_via_devise(CUSTOMER_EMAIL, DEMO_PASSWORD, "CUSTOMER")
results[:devise_customer_token_role] = d_customer[:claims]["role"]
rc, cal = get_json("/kiosk/salon_calendar",
                   { "Authorization" => "Bearer #{d_customer[:token]}" })
abort "CUSTOMER (real Devise) salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
c_rows = Array(cal)
results[:devise_customer_sees_forecast] = c_rows.any? { |r| r["summary"] == "forecast" }
results[:devise_customer_row_count]     = c_rows.size
STDERR.puts "  CUSTOMER (real Devise) role=#{results[:devise_customer_token_role].inspect} sees #{c_rows.size} rows, forecast_row=#{results[:devise_customer_sees_forecast]}"

puts JSON.generate(results)
