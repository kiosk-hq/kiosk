# frozen_string_literal: true

# roles-from-IdP driver (Path A) — the INDIRECT, human-idp path.
#
# A salon STAFF member links their assistant (W5 link-code ceremony); the
# assistant INHERITS the human's role, sourced from the provider's own IdP at
# link time — never self-selected by the agent. kiosk-server captures that role
# onto the link row at mint and sets the bound agent's allowed_roles from it.
# The `salon_calendar` query then gates on kiosk.current_role():
#
#   OWNER  links an assistant → token role == owner   → salon_calendar returns
#          ALL of the salon's appointments + a revenue total.
#   STYLIST links an assistant → token role == stylist → salon_calendar returns
#          ONLY that stylist's own chairs.
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
OWNER_ID    = "00000000-0000-0000-0000-0000000000a0"
STYLIST1_ID = "00000000-0000-0000-0000-0000000000b1" # Bea — owns 2 seeded chairs

# Seeded Devise credentials for the real-sign-in (K-437) path.
DEMO_PASSWORD  = "combette-demo-password"
OWNER_EMAIL    = "owner@combette.example"
STYLIST1_EMAIL = "bea@combette.example"
CUSTOMER_ID    = "00000000-0000-0000-0000-000000000001" # Alice — a customer (no staff_role)
CUSTOMER_EMAIL = "alice@example.com"

def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, headers = {})
  uri = URI("#{SERVER}#{path}")
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
rc, cal = post_json("/kiosk/query", { name: "salon_calendar" },
                    { "Authorization" => "Bearer #{owner[:token]}" })
abort "OWNER salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
owner_rows    = cal.fetch("rows", [])
owner_summary = owner_rows.find { |r| r["summary"] == "revenue" }
owner_appts   = owner_rows.reject { |r| r["summary"] }
results[:owner_appt_count]    = owner_appts.size
results[:owner_revenue_cents] = owner_summary && owner_summary["revenue_cents"]
STDERR.puts "  OWNER sees #{owner_appts.size} appointments; revenue=#{results[:owner_revenue_cents]} cents"

# ══ STYLIST links an assistant → role stylist → salon_calendar = own only ═══
stylist = link_assistant_as(STYLIST1_ID, "STYLIST")
results[:stylist_token_role] = stylist[:claims]["role"]
rc, cal = post_json("/kiosk/query", { name: "salon_calendar" },
                    { "Authorization" => "Bearer #{stylist[:token]}" })
abort "STYLIST salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
stylist_rows = cal.fetch("rows", [])
results[:stylist_appt_count]   = stylist_rows.size
# Every row the stylist sees must be their own chair.
results[:stylist_all_own]      = stylist_rows.all? { |r| r["stylist_id"] == STYLIST1_ID }
results[:stylist_sees_revenue] = stylist_rows.any? { |r| r["summary"] == "revenue" }
STDERR.puts "  STYLIST sees #{stylist_rows.size} appointments; all own=#{results[:stylist_all_own]}; revenue row=#{results[:stylist_sees_revenue]}"

# ══ REAL DEVISE PATH (K-437) — the whole point: the role must survive the real
#    /users/sign_in session, not just the stub. Owner/stylist/customer each sign
#    in for real, mint over the session cookie, and the token role + calendar
#    scope must match. Without User#kiosk_role the Devise adapter falls back to
#    roles.first (customer), so the owner's token comes back "customer" and the
#    calendar is empty — these three assertions FAIL. ══════════════════════════

# OWNER through the real Devise session → role owner, whole book.
d_owner = link_assistant_via_devise(OWNER_EMAIL, DEMO_PASSWORD, "OWNER")
results[:devise_owner_token_role] = d_owner[:claims]["role"]
rc, cal = post_json("/kiosk/query", { name: "salon_calendar" },
                    { "Authorization" => "Bearer #{d_owner[:token]}" })
abort "OWNER (real Devise) salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
d_owner_rows  = cal.fetch("rows", [])
d_owner_appts = d_owner_rows.reject { |r| r["summary"] }
results[:devise_owner_appt_count] = d_owner_appts.size
STDERR.puts "  OWNER (real Devise) role=#{results[:devise_owner_token_role].inspect} sees #{d_owner_appts.size} appointments"

# STYLIST through the real Devise session → role stylist, only own chairs.
d_stylist = link_assistant_via_devise(STYLIST1_EMAIL, DEMO_PASSWORD, "STYLIST")
results[:devise_stylist_token_role] = d_stylist[:claims]["role"]
rc, cal = post_json("/kiosk/query", { name: "salon_calendar" },
                    { "Authorization" => "Bearer #{d_stylist[:token]}" })
abort "STYLIST (real Devise) salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
d_stylist_rows = cal.fetch("rows", [])
results[:devise_stylist_appt_count] = d_stylist_rows.size
results[:devise_stylist_all_own]    = d_stylist_rows.all? { |r| r["stylist_id"] == STYLIST1_ID }
STDERR.puts "  STYLIST (real Devise) role=#{results[:devise_stylist_token_role].inspect} sees #{d_stylist_rows.size} appointments; all own=#{results[:devise_stylist_all_own]}"

# CUSTOMER through the real Devise session → role customer, empty calendar.
d_customer = link_assistant_via_devise(CUSTOMER_EMAIL, DEMO_PASSWORD, "CUSTOMER")
results[:devise_customer_token_role] = d_customer[:claims]["role"]
rc, cal = post_json("/kiosk/query", { name: "salon_calendar" },
                    { "Authorization" => "Bearer #{d_customer[:token]}" })
abort "CUSTOMER (real Devise) salon_calendar failed (#{rc}): #{JSON.generate(cal)}" unless rc == 200
results[:devise_customer_appt_count] = cal.fetch("rows", []).size
STDERR.puts "  CUSTOMER (real Devise) role=#{results[:devise_customer_token_role].inspect} sees #{results[:devise_customer_appt_count]} appointments"

puts JSON.generate(results)
