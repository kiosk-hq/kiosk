# frozen_string_literal: true

# Adversarial regression battery for tudu (multi-user collaborative todo app).
#
# Runs a set of attacks against the live surface (my_lists / list_todos /
# list_members queries; create_list / add_todo / complete_todo / invite /
# accept_invite / remove_member actions) and asserts each is BLOCKED. tudu has
# no payment or KYC surface, so the battery covers the attacks that apply —
# membership isolation, forged principal args, the auth/dispatch boundary, PLUS
# tudu-specific collaboration attacks (invite replay, revoked-member access,
# revoked-agent login, pre-link token reach).
#
# Standard scenarios (each must be BLOCKED):
#   CrossTenantRead   — a non-member's list_todos on a private list → 403
#   ForgedUserId      — forged account_id on create_list ignored (belongs to caller)
#   MissingAuth       — a request with no Authorization → 401
#   GarbageToken      — an unparseable bearer token → 401
#   UnknownQuery      — an unregistered query name → 404
#   UnknownAction     — an unregistered action name → 404
# tudu-specific scenarios:
#   InviteCodeReplay      — an already-used invite code is rejected → 403
#   RevokedMemberAccess   — a removed member's next read is blocked → 403
#   RevokedAgentKey       — an unlinked agent's login is denied → 404
#   PreLinkTokenAfterLink — a token minted before rebind can't reach the
#                           migrated list → 403 (its principal owns nothing now)
#
# Usage:
#   SERVER_URL=… KIOSK_ISSUER=… HOLDER_ID=… HOLDER_EMAIL=… HOLDER_PASSWORD=… \
#   bundle exec ruby redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED (0 BREACH); exits 1 on any BREACH.

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
HOLDER   = ENV.fetch("HOLDER_ID")
EMAIL    = ENV.fetch("HOLDER_EMAIL")
PASSWORD = ENV.fetch("HOLDER_PASSWORD")

COOKIES = {}
SERVER_URI = URI(SERVER)

def absorb_cookies!(res)
  Array(res.get_fields("set-cookie")).each do |line|
    name, value = line.split(";").first.split("=", 2)
    COOKIES[name] = value
  end
end

def cookie_header = COOKIES.map { |k, v| "#{k}=#{v}" }.join("; ")

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

def bearer(token) = { "Authorization" => "Bearer #{token}" }
def csrf_token(html) = html[/name="authenticity_token" value="([^"]+)"/, 1]

def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc})" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

def register_agent(label)
  key = OpenSSL::PKey::RSA.generate(2048)
  pem = key.public_key.to_pem
  rc, reg = post_json("/kiosk/auth/register", { public_key: pem, signed: pop_proof(key, pem) })
  abort "#{label} register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  { key: key, pem: pem, token: reg.fetch("access_token"), agent_id: reg.fetch("agent_id"), user_id: reg.fetch("user_id") }
end

results = []
def record(results, name, blocked, detail)
  results << { name: name, blocked: blocked, detail: detail }
  puts "  #{blocked ? 'BLOCKED' : 'BREACH '}  #{name} — #{detail}"
end

# ── Fixtures: an owner with a private list; a member; an outsider ────────────
owner    = register_agent("owner")
member   = register_agent("member")
outsider = register_agent("outsider")

rc, created = post_json("/kiosk/run", { name: "create_list", title: "Redteam target" }, bearer(owner[:token]))
abort "owner create_list failed (#{rc}) — run rake demo:setup" unless rc == 200
list_id = created.dig("value", "list_id")
rc, inv = post_json("/kiosk/run", { name: "invite", list_id: list_id }, bearer(owner[:token]))
invite_code = inv.dig("value", "code")
post_json("/kiosk/run", { name: "accept_invite", code: invite_code }, bearer(member[:token]))

# ── CrossTenantRead — outsider list_todos on the private list → 403 ──────────
rc, = post_json("/kiosk/query", { name: "list_todos", list_id: list_id }, bearer(outsider[:token]))
record(results, "CrossTenantRead", rc == 403, "outsider list_todos → #{rc} (want 403)")

# ── ForgedUserId — outsider create_list with a forged account_id → ignored ──
rc, forged = post_json("/kiosk/run",
                       { name: "create_list", title: "Forged", account_id: owner[:user_id] },
                       bearer(outsider[:token]))
forged_list = forged.dig("value", "list_id")
# The forged list must NOT appear in the owner's my_lists (it belongs to outsider).
rc_o, o_lists = post_json("/kiosk/query", { name: "my_lists" }, bearer(owner[:token]))
o_ids = (o_lists["rows"] || []).map { |r| r["list_id"] }
record(results, "ForgedUserId", rc == 200 && rc_o == 200 && !o_ids.include?(forged_list),
       "owner's lists exclude outsider's forged list #{forged_list.inspect}")

# ── MissingAuth / GarbageToken → 401 ────────────────────────────────────────
rc, = post_json("/kiosk/query", { name: "my_lists" })
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")
rc, = post_json("/kiosk/query", { name: "my_lists" }, bearer("not-a-real-token"))
record(results, "GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── UnknownQuery / UnknownAction → 404 ──────────────────────────────────────
rc, = post_json("/kiosk/query", { name: "frobnicate" }, bearer(owner[:token]))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")
rc, = post_json("/kiosk/run", { name: "nope" }, bearer(owner[:token]))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── InviteCodeReplay — the member's used code, replayed by outsider → 403 ────
rc, = post_json("/kiosk/run", { name: "accept_invite", code: invite_code }, bearer(outsider[:token]))
record(results, "InviteCodeReplay", rc == 403, "replay of used invite code → #{rc} (want 403)")

# ── RevokedMemberAccess — remove the member, its next read is blocked → 403 ─
post_json("/kiosk/run", { name: "remove_member", list_id: list_id, account_id: member[:user_id] }, bearer(owner[:token]))
rc, = post_json("/kiosk/query", { name: "list_todos", list_id: list_id }, bearer(member[:token]))
record(results, "RevokedMemberAccess", rc == 403, "removed member's next read → #{rc} (want 403)")

# ── Session-channel scenarios: Alice signs in for unlink + link ─────────────
signin = get_html("/users/sign_in")
post_form("/users/sign_in",
          "authenticity_token" => csrf_token(signin.body),
          "user[email]" => EMAIL, "user[password]" => PASSWORD)

# RevokedAgentKey — link a fresh assistant to Alice, unlink it, login → 404.
rc, link = post_json("/kiosk/auth/link", {}, { session: true })
rk = OpenSSL::PKey::RSA.generate(2048); rpem = rk.public_key.to_pem
rc, claimed = post_json("/kiosk/auth/claim", { code: link["link_code"], public_key: rpem, signed: pop_proof(rk, rpem) })
revoked_agent_id = claimed["agent_id"]
post_json("/kiosk/auth/unlink", { agent_id: revoked_agent_id }, { session: true })
rc, = post_json("/kiosk/auth/login", { public_key: rpem, signed: pop_proof(rk, rpem) })
record(results, "RevokedAgentKey", rc == 404, "unlinked agent login → #{rc} (want 404)")

# PreLinkTokenAfterLink — an agent registers headless, creates a list, then
# rebinds to Alice (assistant_claimed migrates the list). The PRE-LINK token's
# principal (the old headless account) owns nothing now → its list_todos on the
# migrated list is BLOCKED (403). (Shipped rebind remaps the principal rather
# than watermark-revoking the token; the access denial is the honest signal.)
pl = register_agent("prelink")
rc, plc = post_json("/kiosk/run", { name: "create_list", title: "Pre-link list" }, bearer(pl[:token]))
pl_list = plc.dig("value", "list_id")
rc, link2 = post_json("/kiosk/auth/link", {}, { session: true })
rc, = post_json("/kiosk/auth/claim", { code: link2["link_code"], public_key: pl[:pem], signed: pop_proof(pl[:key], pl[:pem]) })
rc, = post_json("/kiosk/query", { name: "list_todos", list_id: pl_list }, bearer(pl[:token]))
record(results, "PreLinkTokenAfterLink", rc == 403,
       "pre-link token reading the migrated list → #{rc} (want 403 — principal migrated away)")

# ── Verdict ──────────────────────────────────────────────────────────────────
breaches = results.reject { |r| r[:blocked] }
puts JSON.generate(scenarios: results.size, blocked: results.count { |r| r[:blocked] }, breaches: breaches.map { |r| r[:name] })

if breaches.empty?
  puts "\n  redteam: all #{results.size} scenarios BLOCKED."
  exit 0
else
  puts "\n  redteam: #{breaches.size} BREACH(es): #{breaches.map { |r| r[:name] }.join(', ')}"
  exit 1
end
