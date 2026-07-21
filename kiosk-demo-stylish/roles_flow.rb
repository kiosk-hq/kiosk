# frozen_string_literal: true

# roles-from-IdP driver (Path A) — the INDIRECT, human-idp path.
#
# A salon STAFF member links their assistant (W5 link-code ceremony) over a
# role-carrying session (the StubUserIdp SSO/Okta stand-in: an
# `X-Staff-Session: <user_id>` header naming the signed-in staff member,
# whose staff_role becomes the session role). kiosk-server captures that role
# onto the link row at mint and sets the bound agent's allowed_roles from it —
# so the assistant INHERITS the human's role. The `salon_calendar` query then
# gates on kiosk.current_role():
#
#   OWNER  links an assistant → token role == owner   → salon_calendar returns
#          ALL of the salon's appointments + a revenue total.
#   STYLIST links an assistant → token role == stylist → salon_calendar returns
#          ONLY that stylist's own chairs.
#
# The role rides the token, sourced from the IdP — never self-selected by the
# agent. Prints ONE JSON line; non-zero exit on any hard failure.

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

# Link an assistant as the given staff member (role-carrying StubUserIdp
# session), returning the minted token's claims.
def link_assistant_as(staff_user_id, label)
  # The human mints a link code over the role-carrying session.
  rc, link = post_json("/kiosk/auth/link", {}, { "X-Staff-Session" => staff_user_id })
  abort "#{label}: link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201
  code = link.fetch("link_code")

  # The assistant redeems it with a fresh key + possession proof.
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

puts JSON.generate(results)
