# frozen_string_literal: true

# tudu account-link driver — the W5 REBIND + DOMAIN-MIGRATION beat, the first
# real use of the assistant_claimed hook in the repo.
#
# Scenario (all over real HTTP against the live app):
#   1. An assistant registers with a FRESH key as a HEADLESS account (PoP
#      register → its own users row, no human behind it) and, as that headless
#      account, creates the "Hike" list.
#   2. The human (Alice) signs in through the real Devise form, and mints a
#      LINK code (POST /kiosk/auth/link, session channel).
#   3. The SAME assistant key redeems the code (POST /kiosk/auth/claim, key+PoP)
#      → REBIND: agent_id stays stable, agents.user_id remaps to Alice, and the
#      assistant_claimed hook MIGRATES the headless account's list to Alice.
#
# Asserts:
#   (a) after link, the pre-existing "Hike" list now belongs to Alice
#       (assistant_claimed migrated it — verified in the rake task via psql);
#   (b) the PRE-LINK token no longer authenticates at all — a rebind is a
#       principal change, so (like unlink) it watermark-revokes the key's
#       pre-link tokens. The old token now fails with 401, forcing the
#       agent to re-login for a token under the new principal.
#   (c) after the assistant RE-LOGS IN (fresh token, sub=Alice), it sees "Hike"
#       under Alice — and Alice's browser session (my_lists as the human) sees
#       the same list. One shared world.
#   (d) Alice ends with the linked agent bound to her (DB ground truth).

require "date"
require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"
require "base64"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
HOLDER   = ENV.fetch("HOLDER_ID")
EMAIL    = ENV.fetch("HOLDER_EMAIL")
PASSWORD = ENV.fetch("HOLDER_PASSWORD")

COOKIES = {}

def absorb_cookies!(res)
  Array(res.get_fields("set-cookie")).each do |line|
    name, value = line.split(";").first.split("=", 2)
    COOKIES[name] = value
  end
end

def cookie_header = COOKIES.map { |k, v| "#{k}=#{v}" }.join("; ")

SERVER_URI = URI(SERVER)

def request(req)
  res = Net::HTTP.new(SERVER_URI.host, SERVER_URI.port).request(req)
  absorb_cookies!(res)
  res
end

def get_html(path)
  req = Net::HTTP::Get.new(URI("#{SERVER}#{path}"))
  req["Cookie"] = cookie_header unless COOKIES.empty?
  request(req)
end

def post_form(path, form)
  req = Net::HTTP::Post.new(URI("#{SERVER}#{path}"))
  req["Cookie"] = cookie_header unless COOKIES.empty?
  req.set_form_data(form)
  request(req)
end

def post_json(path, body, headers = {})
  session = headers.delete(:session)
  req = Net::HTTP::Post.new(URI("#{SERVER}#{path}"), { "Content-Type" => "application/json" }.merge(headers))
  req["Cookie"] = cookie_header if session
  req.body = JSON.generate(body)
  res = request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path)
  res = request(Net::HTTP::Get.new(URI("#{SERVER}#{path}")))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def csrf_token(html) = html[/name="authenticity_token" value="([^"]+)"/, 1]

def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

def jwt_claims(token)
  seg = token.split(".")[1]
  JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

results = {}

# ── 1. Assistant registers HEADLESS and creates the "Hike" list ─────────────
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
pop = pop_proof(key, pem)
rc, reg = post_json("/kiosk/auth/register", { public_key: pem, signed: pop })
abort "headless register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
headless_token   = reg.fetch("access_token")
agent_id         = reg.fetch("agent_id")
headless_user_id = reg.fetch("user_id")
results[:headless_agent_id]    = agent_id
results[:headless_user_id]     = headless_user_id
STDERR.puts "  Assistant registered headless: agent_id=#{agent_id} user_id=#{headless_user_id}"

rc, created = post_json("/kiosk/run", { name: "create_list", title: "Hike" }, bearer(headless_token))
abort "headless create_list failed (#{rc}): #{JSON.generate(created)}" unless rc == 200
list_id = created.dig("value", "list_id")
results[:list_id] = list_id
STDERR.puts "  Headless assistant created list #{list_id}"

# ── 2. Human signs in and mints a link code ─────────────────────────────────
signin = get_html("/users/sign_in")
abort "sign-in form: #{signin.code}" unless signin.code.to_i == 200
res = post_form("/users/sign_in",
                "authenticity_token" => csrf_token(signin.body),
                "user[email]"        => EMAIL,
                "user[password]"     => PASSWORD)
abort "sign-in failed: #{res.code}" unless [302, 303].include?(res.code.to_i)
results[:human_signed_in] = true

rc, link = post_json("/kiosk/auth/link", {}, { session: true })
results[:link_mint] = rc
abort "link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201

# ── 3. The SAME key redeems the code → REBIND + assistant_claimed migration ──
# The rebind watermark-revokes tokens minted STRICTLY before it (JWT iat is
# second-resolution). Cross a second boundary so the pre-link token, minted
# above, is unambiguously older than the rebind instant — over a real network
# these steps span seconds; the sleep just makes the local demo deterministic.
sleep 1.1
rc, claimed = post_json("/kiosk/auth/claim",
                        { code: link.fetch("link_code", ""), public_key: pem, signed: pop_proof(key, pem) })
results[:claim_status]        = rc
results[:claim_rebound_to_holder] = claimed["user_id"] == HOLDER
results[:claim_same_agent_id] = claimed["agent_id"] == agent_id
abort "claim failed (#{rc}): #{JSON.generate(claimed)}" unless rc == 201
STDERR.puts "  Rebind: agent_id=#{claimed['agent_id']} now user_id=#{claimed['user_id']} (was #{headless_user_id})"

# (b) The PRE-LINK token is watermark-revoked by the rebind (principal change ⇒
#     the agent must re-login) — its next call is rejected 401, not merely empty.
rc, _prelink = post_json("/kiosk/query", { name: "my_lists" }, bearer(headless_token))
results[:prelink_status]   = rc
results[:prelink_revoked]  = rc == 401

# (c) The assistant RE-LOGS IN (fresh token bound to Alice) and sees "Hike".
rc, relog = post_json("/kiosk/auth/login", { public_key: pem, signed: pop_proof(key, pem) })
abort "re-login failed (#{rc}): #{JSON.generate(relog)}" unless rc == 200
new_token = relog.fetch("access_token")
results[:relogin_sub_is_holder] = jwt_claims(new_token)["sub"] == HOLDER
rc, after = post_json("/kiosk/query", { name: "my_lists" }, bearer(new_token))
results[:agent_sees_migrated_list] = rc == 200 && (after["rows"] || []).any? { |r| r["list_id"] == list_id && r["role"] == "owner" }

# Alice's browser session sees the same list over the web (my_lists as human).
alice_view = get_html("/lists")
results[:human_sees_migrated_list] = alice_view.code.to_i == 200 && alice_view.body.include?("Hike")

# Link a SECOND assistant to Alice so she ends with >=2 non-revoked agents.
rc, link2 = post_json("/kiosk/auth/link", {}, { session: true })
key2 = OpenSSL::PKey::RSA.generate(2048)
pem2 = key2.public_key.to_pem
rc, claimed2 = post_json("/kiosk/auth/claim",
                         { code: link2.fetch("link_code", ""), public_key: pem2, signed: pop_proof(key2, pem2) })
results[:second_agent_id]        = claimed2["agent_id"]
results[:second_bound_to_holder] = claimed2["user_id"] == HOLDER

puts JSON.generate(results)
