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
# This flow exercises the role source through BOTH provider channels, because a
# role that only resolves through the stub is a role that does not work for a
# real operator (K-437):
#
#   • STUB path (the SSO/Okta stand-in): an `X-Staff-Session: <user_id>` header
#     naming the signed-in staff member, read by StubUserIdp.
#   • REAL DEVISE path (what the hosted demo + real operators use): the staff
#     member signs in through the real /users/sign_in form and mints the link
#     over that Devise session cookie — no staff header — so the role is
#     resolved by Kiosk::UserIdentityProviders::Devise off the User model's
#     `#kiosk_role`. This is the path Phil hit live where the owner's token came
#     back `customer`.
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

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# Seeded staff (db/seeds.rb).
OWNER_ID = "00000000-0000-0000-0000-0000000000a0"

# Seeded Devise credentials for the real-sign-in (K-437) path.
DEMO_PASSWORD  = "combette-demo-password"
OWNER_EMAIL    = "owner@combette.example"
CUSTOMER_ID    = "00000000-0000-0000-0000-000000000001" # Alice — a customer (no staff_role)
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

# ── STUB path: mint the link over the role-carrying StubUserIdp session ──────
# (the SSO/Okta stand-in: an `X-Staff-Session` header naming the staff member).
def link_assistant_as(staff_user_id, label)
  rc, link = post_json("/kiosk/auth/link", {}, { "X-Staff-Session" => staff_user_id })
  abort "#{label}: link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201
  claim_link(link.fetch("link_code"), label)
end

# ── REAL DEVISE path (K-437): sign in through the real /users/sign_in form,
#    then mint the link over that session cookie — NO staff header — so the
#    role is resolved by Kiosk::UserIdentityProviders::Devise off the User
#    model's #kiosk_role, exactly as a hosted-demo operator experiences it. ──
#
# Uses its own cookie jar per call so each principal is an independent session.
def link_assistant_via_devise(email, password, label)
  cookies = {}
  server_uri = URI(SERVER)

  absorb = lambda do |res|
    Array(res.get_fields("set-cookie")).each do |line|
      name, value = line.split(";").first.split("=", 2)
      cookies[name] = value
    end
    res
  end
  cookie_header = -> { cookies.map { |k, v| "#{k}=#{v}" }.join("; ") }

  get_html = lambda do |path|
    req = Net::HTTP::Get.new(URI("#{SERVER}#{path}"))
    req["Cookie"] = cookie_header.call unless cookies.empty?
    absorb.call(Net::HTTP.new(server_uri.host, server_uri.port).request(req))
  end
  post_form = lambda do |path, form|
    req = Net::HTTP::Post.new(URI("#{SERVER}#{path}"))
    req["Cookie"] = cookie_header.call unless cookies.empty?
    req.set_form_data(form)
    absorb.call(Net::HTTP.new(server_uri.host, server_uri.port).request(req))
  end

  # Real Devise sign-in: GET the form for the CSRF token, POST credentials.
  signin = get_html.call("/users/sign_in")
  abort "#{label}: sign-in form: #{signin.code}" unless signin.code.to_i == 200
  csrf = signin.body[/name="authenticity_token" value="([^"]+)"/, 1]
  res  = post_form.call("/users/sign_in",
                        "authenticity_token" => csrf,
                        "user[email]"        => email,
                        "user[password]"     => password)
  abort "#{label}: sign-in failed: #{res.code}" unless [302, 303].include?(res.code.to_i)

  # Mint the link code over the Devise session cookie ONLY — no X-Staff-Session,
  # so CompositeUserIdp falls through to the real Devise adapter.
  req = Net::HTTP::Post.new(URI("#{SERVER}/kiosk/auth/link"), "Content-Type" => "application/json")
  req["Cookie"] = cookie_header.call
  req.body = JSON.generate({})
  res = Net::HTTP.new(server_uri.host, server_uri.port).request(req)
  rc  = res.code.to_i
  link = (JSON.parse(res.body) rescue {})
  abort "#{label} (real Devise): link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201

  claim_link(link.fetch("link_code"), "#{label} (real Devise)")
end

results = {}

# ══ OWNER links an assistant → role owner → salon_calendar = whole book ═════
owner = link_assistant_as(OWNER_ID, "OWNER")
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
STDERR.puts "  OWNER sees #{owner_bookings.size} bookings; forecast=#{results[:owner_forecast_cents]} cents"

# ══ REAL DEVISE PATH (K-437) — the whole point: the role must survive the real
#    /users/sign_in session, not just the stub. Owner/customer each sign in for
#    real, mint over the session cookie, and the token role + calendar scope
#    must match. Without User#kiosk_role the Devise adapter falls back to
#    roles.first (customer), so the owner's token comes back "customer" and the
#    forecast disappears — these assertions FAIL. ══════════════════════════════

# OWNER through the real Devise session → role owner, whole book + forecast.
d_owner = link_assistant_via_devise(OWNER_EMAIL, DEMO_PASSWORD, "OWNER")
results[:devise_owner_token_role] = d_owner[:claims]["role"]
rc, cal = get_json("/kiosk/salon_calendar",
                   { "Authorization" => "Bearer #{d_owner[:token]}" })
abort "OWNER (real Devise) salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
d_owner_rows = Array(cal)
results[:devise_owner_sees_forecast] = d_owner_rows.any? { |r| r["summary"] == "forecast" }
STDERR.puts "  OWNER (real Devise) role=#{results[:devise_owner_token_role].inspect} forecast_row=#{results[:devise_owner_sees_forecast]}"

# CUSTOMER through the real Devise session → role customer, own bookings, no forecast.
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
