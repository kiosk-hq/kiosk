# frozen_string_literal: true

# Red-team battery for tudu: attacks a running server and asserts every attack is refused.
# Usage: SERVER_URL=http://127.0.0.1:3007 bundle exec ruby script/redteam_suite.rb

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

require "kiosk/redteam"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = SERVER
HOLDER   = "00000000-0000-0000-0000-000000000001"
EMAIL    = "alice@example.com"
PASSWORD = "tudu-demo-password"

require "kiosk/user_identity_providers/devise_session"

# WIRE carries an agent's Bearer call; SESSION is the human's browser, for the binding ceremony.
WIRE    = Kiosk::TestHelpers::Wire.new(base_url: SERVER)
SESSION = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)

def request(req) = SESSION.request(req)

def post_json(path, body, headers = {}) = SESSION.post_json(path, body, headers)
def get_json(path, params = {}, headers = {}) = SESSION.get_json(path, params, headers)

def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc})" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

require_relative "equihash_register"

# equihash_register calls full URLs; tudu's helpers take a path.
GET_URL  = ->(url)                 { get_json(url.delete_prefix(SERVER)) }
POST_URL = ->(url, body, hdrs = {}) { post_json(url.delete_prefix(SERVER), body, hdrs) }

def register_agent(_label)
  key, reg = equihash_register(server: SERVER, issuer: ISSUER, get_json: GET_URL, post_json: POST_URL)
  { key: key, pem: key.public_key.to_pem,
    token: reg.fetch("access_token"), agent_id: reg.fetch("agent_id"), user_id: reg.fetch("user_id") }
end

BATTERY = Kiosk::Redteam::Battery.new

# Fixtures: an owner with a private list, a member, an outsider.
owner    = register_agent("owner")
member   = register_agent("member")
outsider = register_agent("outsider")

rc, created = post_json("/kiosk/create_list", { title: "Redteam target" }, WIRE.bearer(owner[:token]))
abort "owner create_list failed (#{rc}) — run bin/rails db:reset" unless rc == 200
list_id = created["list_id"]
rc, inv = post_json("/kiosk/invite", { list_id: list_id }, WIRE.bearer(owner[:token]))
invite_code = inv["code"]
post_json("/kiosk/accept_invite", { code: invite_code }, WIRE.bearer(member[:token]))

rc, = get_json("/kiosk/list_todos", { list_id: list_id }, WIRE.bearer(outsider[:token]))
BATTERY.record("CrossTenantRead", rc == 403, "outsider list_todos → #{rc} (want 403)")

# The principal is not an input of create_list, so a forged account_id is refused with a 400.
rc, forged = post_json("/kiosk/create_list",
                       { title: "Forged", account_id: owner[:user_id] },
                       WIRE.bearer(outsider[:token]))
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("account_id")

rc_x, outsiders = post_json("/kiosk/create_list", { title: "Outsider's own" }, WIRE.bearer(outsider[:token]))
outsider_list = outsiders["list_id"]
rc_o, o_lists = get_json("/kiosk/my_lists", {}, WIRE.bearer(owner[:token]))
o_ids = Array(o_lists).map { |r| r["list_id"] }
BATTERY.record("ForgedUserId",
               refused && rc_x == 200 && rc_o == 200 && !o_ids.include?(outsider_list),
               "forged account_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming account_id); " \
               "owner's lists #{o_ids.inspect} exclude the outsider's #{outsider_list.inspect}")

# Junk ids must be a typed 400 naming the argument, never a 500 carrying SQL internals.
MALFORMED_IDS = ["not-a-uuid", "1; DROP TABLE todos", "", "  "].freeze
SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

uuid_probes = MALFORMED_IDS.flat_map do |junk|
  [
    # A query: the junk rides the query string.
    [-> { get_json("/kiosk/list_todos", { list_id: junk }, WIRE.bearer(owner[:token])) },
     "list_todos", "list_id"],
    [-> { post_json("/kiosk/complete_todo", { todo_id: junk }, WIRE.bearer(owner[:token])) },
     "complete_todo", "todo_id"],
    # The second id, on a verb whose first id is well-formed.
    [-> { post_json("/kiosk/remove_member", { list_id: list_id, account_id: junk }, WIRE.bearer(owner[:token])) },
     "remove_member", "account_id"],
  ].map do |probe, verb, arg|
    rc, resp = probe.call
    # tudu echoes the bad id back; `supplied:` keeps that echo from reading as a leak.
    scan = Kiosk::Redteam::LeakScan.scan(resp, SQL_INTERNALS, supplied: junk)
    ok = rc == 400 && resp["code"] == "bad_request" &&
         resp["detail"].to_s.include?(arg) && !scan.leak?
    [ok, "#{verb}(#{junk.inspect})→#{rc}/#{resp['code'].inspect}" \
         "#{scan.leak ? " LEAK #{scan.leak}" : ''}#{scan.note}"]
  end
end
BATTERY.record("MalformedUuidArg", uuid_probes.all? { |ok, _| ok },
               "malformed list_id/todo_id/account_id → #{uuid_probes.map(&:last).join(', ')} " \
               "(want 400/\"bad_request\", a detail naming the argument, and no SQL internals)")

rc, = get_json("/kiosk/my_lists")
BATTERY.record("MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")
rc, = get_json("/kiosk/my_lists", {}, WIRE.bearer("not-a-real-token"))
BATTERY.record("GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

rc, = get_json("/kiosk/frobnicate", {}, WIRE.bearer(owner[:token]))
BATTERY.record("UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")
rc, = post_json("/kiosk/nope", {}, WIRE.bearer(owner[:token]))
BATTERY.record("UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# A multiplexed-endpoint name is an ordinary 404, with or without a bearer.
unregistered = %w[query run].flat_map do |name|
  authed = WIRE.request(:post, "/kiosk/#{name}", body: { name: "my_lists" },
                        headers: WIRE.bearer(owner[:token]))
  anon   = WIRE.request(:post, "/kiosk/#{name}", body: { name: "my_lists" })
  [[authed.status == 404 && authed.body["code"].nil?, "#{name}→#{authed.status}"],
   [anon.status   == 404 && anon.body["code"].nil?,   "#{name}(anon)→#{anon.status}"]]
end
BATTERY.record("UnregisteredVerbIsOrdinaryRefusal",
               unregistered.all? { |ok, _| ok },
               "unregistered verb names #{unregistered.map(&:last).join(', ')} " \
               "(want a plain 404 with no problem-document code, bearer or not)")

# A GET at an action's path must never reach the action.
res404 = WIRE.request(:get, "/kiosk/create_list", headers: WIRE.bearer(owner[:token]))
BATTERY.record("MethodMismatch",
               res404.status == 404 && res404["allow"].nil? && res404.body["code"].nil?,
               "GET an action → #{res404.status} Allow=#{res404['allow'].inspect} " \
               "(want a plain 404, no Allow, no problem-document code)")

rc, = post_json("/kiosk/accept_invite", { code: invite_code }, WIRE.bearer(outsider[:token]))
BATTERY.record("InviteCodeReplay", rc == 403, "replay of used invite code → #{rc} (want 403)")

post_json("/kiosk/remove_member", { list_id: list_id, account_id: member[:user_id] }, WIRE.bearer(owner[:token]))
rc, = get_json("/kiosk/list_todos", { list_id: list_id }, WIRE.bearer(member[:token]))
BATTERY.record("RevokedMemberAccess", rc == 403, "removed member's next read → #{rc} (want 403)")

begin
  SESSION.sign_in!(email: EMAIL, password: PASSWORD)
rescue Kiosk::UserIdentityProviders::DeviseSession::SignInError => e
  abort "#{e.message} — RevokedAgentKey needs a live Devise session"
end

# A login that succeeds before unlink proves the final 404 means revoked, not never linked.
rc_link, link = post_json("/kiosk/auth/link", {}, { session: true })
rk = OpenSSL::PKey::RSA.generate(2048); rpem = rk.public_key.to_pem
rc_claim, claimed = post_json("/kiosk/auth/claim", { code: link["link_code"], public_key: rpem, signed: pop_proof(rk, rpem) })
revoked_agent_id = claimed["agent_id"]
rc_prelogin, = post_json("/kiosk/auth/login", { public_key: rpem, signed: pop_proof(rk, rpem) })
rc_unlink, = post_json("/kiosk/auth/unlink", { agent_id: revoked_agent_id }, { session: true })
rc, = post_json("/kiosk/auth/login", { public_key: rpem, signed: pop_proof(rk, rpem) })
BATTERY.record("RevokedAgentKey",
               rc_link == 201 && rc_claim == 201 && !revoked_agent_id.nil? &&
               rc_prelogin == 200 && rc_unlink == 204 && rc == 404,
               "link=#{rc_link} claim=#{rc_claim} agent_id=#{revoked_agent_id.inspect} " \
               "pre-revoke login=#{rc_prelogin} (want 200) unlink=#{rc_unlink} (want 204) " \
               "post-revoke login=#{rc} (want 404)")

# A rebind watermark-revokes the key's pre-link tokens.
pl = register_agent("prelink")
rc, plc = post_json("/kiosk/create_list", { title: "Pre-link list" }, WIRE.bearer(pl[:token]))
pl_list = plc["list_id"]
rc, link2 = post_json("/kiosk/auth/link", {}, { session: true })
# JWT iat is second-resolution: the pre-link token must predate the rebind watermark.
sleep 1.1
rc, = post_json("/kiosk/auth/claim", { code: link2["link_code"], public_key: pl[:pem], signed: pop_proof(pl[:key], pl[:pem]) })
rc, = get_json("/kiosk/list_todos", { list_id: pl_list }, WIRE.bearer(pl[:token]))
BATTERY.record("PreLinkTokenAfterLink", rc == 401,
               "pre-link token after rebind → #{rc} (want 401 — watermark-revoked)")

# A co-member's roster must name people by display_name, never by login address (§7.2).
pii_rc_link, pii_link = post_json("/kiosk/auth/link", {}, { session: true })
pii_key = OpenSSL::PKey::RSA.generate(2048)
pii_pem = pii_key.public_key.to_pem
pii_rc_claim, = post_json("/kiosk/auth/claim",
                          { code: pii_link["link_code"], public_key: pii_pem, signed: pop_proof(pii_key, pii_pem) })
pii_rc_login, pii_login = post_json("/kiosk/auth/login",
                                    { public_key: pii_pem, signed: pop_proof(pii_key, pii_pem) })
pii_bearer = WIRE.bearer(pii_login["access_token"].to_s)

rc_mine, mine = get_json("/kiosk/my_lists", {}, pii_bearer)
household = Array(mine).find { |r| r["title"] == "Flat 3B" }
rc_roster, roster = get_json("/kiosk/list_members", { list_id: household && household["list_id"] }, pii_bearer)
rc_who, who = get_json("/kiosk/whoami", {}, pii_bearer)

# A 500 answers with a Hash; guard before indexing so the beat still reports why.
raw_roster   = JSON.generate(roster) + JSON.generate(who)
roster_rows  = roster.is_a?(Array) ? roster : []
who_rows     = who.is_a?(Array) ? who : []
roster_names = roster_rows.map { |r| r["display_name"] }
no_addresses = !raw_roster.include?(EMAIL) && !raw_roster.include?("@")
named        = roster_rows.length >= 2 &&
               roster_names.all? { |n| n.is_a?(String) && !n.strip.empty? }
recognisable = (roster_names & %w[Alice Bob]).sort == %w[Alice Bob]

# Headless accounts get a distinct opaque `member-<12 hex>`; re-invite so the roster has two.
_, rejoin = post_json("/kiosk/invite", { list_id: list_id }, WIRE.bearer(owner[:token]))
post_json("/kiosk/accept_invite", { code: rejoin["code"] }, WIRE.bearer(outsider[:token]))
rc_headless, headless = get_json("/kiosk/list_members", { list_id: list_id }, WIRE.bearer(owner[:token]))
headless_names = (headless.is_a?(Array) ? headless : []).map { |r| r["display_name"] }
opaque_ok = headless_names.length >= 2 &&
            headless_names.all? { |n| n.to_s.match?(/\Amember-[0-9a-f]{12}\z/) } &&
            headless_names.uniq.length == headless_names.length

BATTERY.record("NoLoginAddressOnTheRoster",
               pii_rc_link == 201 && pii_rc_claim == 201 && pii_rc_login == 200 &&
               rc_mine == 200 && rc_roster == 200 && rc_who == 200 && rc_headless == 200 &&
               no_addresses && named && recognisable && opaque_ok,
               "link=#{pii_rc_link} claim=#{pii_rc_claim} login=#{pii_rc_login}; " \
               "list_members on the seeded household as Alice's assistant → #{rc_roster}, " \
               "#{roster_rows.length} rows named #{roster_names.inspect}; whoami → #{rc_who} " \
               "#{who_rows.first&.fetch('display_name', nil).inspect}; account addresses in " \
               "roster+whoami body: #{no_addresses ? 'none' : 'FOUND'}; headless roster → " \
               "#{rc_headless} #{headless_names.inspect} " \
               "(want no address anywhere, every row a non-empty display_name, the seeded " \
               "household reading as Alice+Bob, and each headless account an opaque " \
               "`member-<12 hex>`)")

# Sign-up's chosen name, not the address, is what the Members block shows. Its own cookie jar.
signup       = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)
chosen_name  = "Cassie Housemate"
signup_email = "cassie-#{SecureRandom.hex(4)}@example.com"
signup_form  = signup.get_html("/users/sign_up")
signup_res   = signup.post_form("/users",
                                "authenticity_token"          => signup.csrf_token(signup_form.body),
                                "user[display_name]"          => chosen_name,
                                "user[email]"                 => signup_email,
                                "user[password]"              => PASSWORD,
                                "user[password_confirmation]" => PASSWORD)
lists_page   = signup.get_html("/lists")
# Per-form CSRF: take the token from the new-list form, not the sign-out button above it.
new_list_form = lists_page.body.to_s[%r{<form[^>]*action="/lists"[^>]*>.*?</form>}m].to_s
create_res   = signup.post_form("/lists",
                                "authenticity_token" => signup.csrf_token(new_list_form),
                                "title"              => "Cassie's shelf")
list_page    = signup.get_html(create_res["location"].to_s)
members_html = list_page.body.to_s[%r{<h2>Members</h2>.*?</ul>}m].to_s

BATTERY.record("ChosenNameNeverTheAddress",
               signup_form.code.to_i == 200 && [302, 303].include?(signup_res.code.to_i) &&
               [302, 303].include?(create_res.code.to_i) && list_page.code.to_i == 200 &&
               members_html.include?(chosen_name) && !members_html.include?("@"),
               "sign-up form → #{signup_form.code}, sign-up → #{signup_res.code}, " \
               "create list → #{create_res.code}, list page → #{list_page.code}; members block " \
               "#{members_html.gsub(/\s+/, ' ').strip.inspect} " \
               "(want the chosen name #{chosen_name.inspect} there and no address in it)")

# Shared kiosk-redteam beat; this origin declares a role, so a skip is a breach.
BATTERY.scenario(
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  client:  Kiosk::TestHelpers::Assistant.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer]),
  on_skip: :breach,
)

exit BATTERY.report!
