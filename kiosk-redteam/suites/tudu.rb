# frozen_string_literal: true

# Red-team battery for tudu: attacks a running server and asserts every attack is refused.
# Usage, in kiosk-demo-tudu with its bundle:
#   SERVER_URL=http://127.0.0.1:3007 bundle exec ruby ../kiosk-redteam/suites/tudu.rb

require 'json'
require 'securerandom'

require 'kiosk/redteam'

SERVER   = ENV.fetch('SERVER_URL')
EMAIL    = 'alice@example.com'
PASSWORD = 'tudu-demo-password'

require 'kiosk/user_identity_providers/devise_session'

# WIRE carries an assistant's call and pays the proof-of-work toll its access token owes.
# SESSION is the human's browser, for the binding ceremony.
WIRE    = Kiosk::TestHelpers::Wire.new(base_url: SERVER, pay_tolls: true)
SESSION = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)

# `session: true` in the headers sends the call from the human's browser.
def client(headers) = headers.key?(:session) ? SESSION : WIRE

def post_json(path, body, headers = {}) = client(headers).post_json(path, body, headers)
def get_json(path, params = {}, headers = {}) = client(headers).get_json(path, params, headers)

ASSISTANT = Kiosk::TestHelpers::Assistant.new(base_url: SERVER)

def register_agent
  assistant = ASSISTANT.register!
  { principal: assistant, key: assistant.key, token: assistant.token, agent_id: assistant.agent_id,
    user_id: assistant.user_id }
end

BATTERY = Kiosk::Redteam::Battery.new

# Fixtures: an owner with a private list, a member, an outsider.
owner    = register_agent
member   = register_agent
outsider = register_agent

rc, created = post_json('/kiosk/create_list', { title: 'Redteam target' }, WIRE.dpop(owner[:token], owner[:key]))
abort "owner create_list failed (#{rc}) — run bin/rails db:reset" unless rc == 200
list_id = created['list_id']
_, inv = post_json('/kiosk/invite', { list_id: list_id }, WIRE.dpop(owner[:token], owner[:key]))
invite_code = inv['code']
post_json('/kiosk/accept_invite', { code: invite_code }, WIRE.dpop(member[:token], member[:key]))

rc, = get_json('/kiosk/list_todos', { list_id: list_id }, WIRE.dpop(outsider[:token], outsider[:key]))
BATTERY.record('CrossTenantRead', rc == 403, "outsider list_todos → #{rc} (want 403)")

# The owner is not an input of create_list, so a forged account_id is refused with a 400.
rc, forged = post_json('/kiosk/create_list',
                       { title: 'Forged', account_id: owner[:user_id] },
                       WIRE.dpop(outsider[:token], outsider[:key]))
refused = rc == 400 && forged['code'] == 'bad_request' && forged['detail'].to_s.include?('account_id')

rc_x, outsiders = post_json('/kiosk/create_list', { title: "Outsider's own" }, WIRE.dpop(outsider[:token], outsider[:key]))
outsider_list = outsiders['list_id']
rc_o, o_lists = get_json('/kiosk/my_lists', {}, WIRE.dpop(owner[:token], owner[:key]))
o_ids = Array(o_lists).map { |r| r['list_id'] }
BATTERY.record('ForgedUserId',
               refused && rc_x == 200 && rc_o == 200 && !o_ids.include?(outsider_list),
               "forged account_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming account_id); " \
               "owner's lists #{o_ids.inspect} exclude the outsider's #{outsider_list.inspect}")

# Junk ids must be a typed 400 naming the argument, never a 500 carrying SQL internals.
MALFORMED_IDS = ['not-a-uuid', '1; DROP TABLE todos', '', '  '].freeze
SQL_INTERNALS = ['::uuid', 'PG::', '22P02', 'invalid input syntax'].freeze

uuid_probes = MALFORMED_IDS.flat_map do |junk|
  [
    # A query: the junk rides the query string.
    [-> { get_json('/kiosk/list_todos', { list_id: junk }, WIRE.dpop(owner[:token], owner[:key])) },
     'list_todos', 'list_id'],
    [-> { post_json('/kiosk/complete_todo', { todo_id: junk }, WIRE.dpop(owner[:token], owner[:key])) },
     'complete_todo', 'todo_id'],
    # The second id, on a verb whose first id is well-formed.
    [-> { post_json('/kiosk/remove_member', { list_id: list_id, account_id: junk }, WIRE.dpop(owner[:token], owner[:key])) },
     'remove_member', 'account_id']
  ].map do |probe, verb, arg|
    rc, resp = probe.call
    # tudu echoes the bad id back; `supplied:` keeps that echo from reading as a leak.
    scan = Kiosk::Redteam::LeakScan.scan(resp, SQL_INTERNALS, supplied: junk)
    ok = rc == 400 && resp['code'] == 'bad_request' &&
         resp['detail'].to_s.include?(arg) && !scan.leak?
    [ok, "#{verb}(#{junk.inspect})→#{rc}/#{resp['code'].inspect}" \
         "#{" LEAK #{scan.leak}" if scan.leak}#{scan.note}"]
  end
end
BATTERY.record('MalformedUuidArg', uuid_probes.all? { |ok, _| ok },
               "malformed list_id/todo_id/account_id → #{uuid_probes.map(&:last).join(', ')} " \
               '(want 400/"bad_request", a detail naming the argument, and no SQL internals)')

rc, = get_json('/kiosk/my_lists')
BATTERY.record('MissingAuth', rc == 401, "unauthenticated request → #{rc} (want 401)")
rc, = get_json('/kiosk/my_lists', {}, WIRE.dpop('not-a-real-token', owner[:key]))
BATTERY.record('GarbageToken', rc == 401, "garbage token → #{rc} (want 401)")

# A copied token without its key buys nothing: as a bearer token, or with another key's DPoP proof.
rc_stolen_bearer, = get_json('/kiosk/my_lists', {}, 'Authorization' => "Bearer #{owner[:token]}")
rc_stolen_key,    = get_json('/kiosk/my_lists', {}, WIRE.dpop(owner[:token], outsider[:key]))
BATTERY.record('StolenToken', rc_stolen_bearer == 401 && rc_stolen_key == 401,
               "stolen token as a bearer → #{rc_stolen_bearer}, with the thief's key → #{rc_stolen_key} (want 401 both)")

rc, = get_json('/kiosk/frobnicate', {}, WIRE.dpop(owner[:token], owner[:key]))
BATTERY.record('UnknownQuery', rc == 404, "unknown query → #{rc} (want 404)")
rc, = post_json('/kiosk/nope', {}, WIRE.dpop(owner[:token], owner[:key]))
BATTERY.record('UnknownAction', rc == 404, "unknown action → #{rc} (want 404)")

# A multiplexed-endpoint name is an ordinary 404, with or without a token.
unregistered = %w[query run].flat_map do |name|
  authed = WIRE.request(:post, "/kiosk/#{name}", body: { name: 'my_lists' },
                                                 headers: WIRE.dpop(owner[:token], owner[:key]))
  anon   = WIRE.request(:post, "/kiosk/#{name}", body: { name: 'my_lists' })
  [[authed.status == 404 && authed.body['code'].nil?, "#{name}→#{authed.status}"],
   [anon.status   == 404 && anon.body['code'].nil?,   "#{name}(anon)→#{anon.status}"]]
end
BATTERY.record('UnregisteredVerbIsOrdinaryRefusal',
               unregistered.all? { |ok, _| ok },
               "unregistered verb names #{unregistered.map(&:last).join(', ')} " \
               '(want a plain 404 with no problem-document code, token or not)')

# A GET at an action's path must never reach the action.
res404 = WIRE.request(:get, '/kiosk/create_list', headers: WIRE.dpop(owner[:token], owner[:key]))
BATTERY.record('MethodMismatch',
               res404.status == 404 && res404['allow'].nil? && res404.body['code'].nil?,
               "GET an action → #{res404.status} Allow=#{res404['allow'].inspect} " \
               '(want a plain 404, no Allow, no problem-document code)')

rc, = post_json('/kiosk/accept_invite', { code: invite_code }, WIRE.dpop(outsider[:token], outsider[:key]))
BATTERY.record('InviteCodeReplay', rc == 403, "replay of used invite code → #{rc} (want 403)")

post_json('/kiosk/remove_member', { list_id: list_id, account_id: member[:user_id] }, WIRE.dpop(owner[:token], owner[:key]))
rc, = get_json('/kiosk/list_todos', { list_id: list_id }, WIRE.dpop(member[:token], member[:key]))
BATTERY.record('RevokedMemberAccess', rc == 403, "removed member's next read → #{rc} (want 403)")

begin
  SESSION.sign_in!(email: EMAIL, password: PASSWORD)
rescue Kiosk::UserIdentityProviders::DeviseSession::SignInError => e
  abort "#{e.message} — RevokedAgentKey needs a live Devise session"
end

# A token request that succeeds before unlink proves the final invalid_client means unlinked, not never linked.
rc_link, link = post_json('/kiosk/auth/link', {}, { session: true })
revoked = ASSISTANT.register_client!
rc_claim = ASSISTANT.claim(link['link_code'], revoked).status
pre_token = ASSISTANT.token(revoked)
rc_unlink, = post_json('/kiosk/auth/unlink', { agent_id: revoked.agent_id }, { session: true })
post_token = ASSISTANT.token(revoked)
BATTERY.record('RevokedAgentKey',
               rc_link == 201 && rc_claim == 204 && pre_token.status == 200 && rc_unlink == 204 &&
               post_token.status == 401 && post_token.body['error'] == 'invalid_client',
               "link=#{rc_link} claim=#{rc_claim} (want 204) agent_id=#{revoked.agent_id.inspect} " \
               "token before unlink=#{pre_token.status} (want 200) unlink=#{rc_unlink} (want 204) " \
               "token after unlink=#{post_token.status}/#{post_token.body['error'].inspect} (want 401 invalid_client)")

# A rebind watermark-revokes the key's pre-link tokens.
pl = register_agent
rc, plc = post_json('/kiosk/create_list', { title: 'Pre-link list' }, WIRE.dpop(pl[:token], pl[:key]))
pl_list = plc['list_id']
rc, link2 = post_json('/kiosk/auth/link', {}, { session: true })
# JWT iat is second-resolution: the pre-link token must predate the rebind watermark.
sleep 1.1
ASSISTANT.claim(link2['link_code'], pl[:principal])
rc, = get_json('/kiosk/list_todos', { list_id: pl_list }, WIRE.dpop(pl[:token], pl[:key]))
BATTERY.record('PreLinkTokenAfterLink', rc == 401,
               "pre-link token after rebind → #{rc} (want 401 — watermark-revoked)")

# A co-member's roster must name people by display_name, never by login address (§7.2).
pii_rc_link, pii_link = post_json('/kiosk/auth/link', {}, { session: true })
pii = ASSISTANT.register_client!
pii_rc_claim = ASSISTANT.claim(pii_link['link_code'], pii).status
pii_token = ASSISTANT.token(pii)
pii_rc_token = pii_token.status
pii_auth = WIRE.dpop(pii_token.body['access_token'].to_s, pii.key)

rc_mine, mine = get_json('/kiosk/my_lists', {}, pii_auth)
household = Array(mine).find { |r| r['title'] == 'Flat 3B' }
rc_roster, roster = get_json('/kiosk/list_members', { list_id: household && household['list_id'] }, pii_auth)
rc_who, who = get_json('/kiosk/whoami', {}, pii_auth)

# A 500 answers with a Hash; guard before indexing so the beat still reports why.
raw_roster   = JSON.generate(roster) + JSON.generate(who)
roster_rows  = roster.is_a?(Array) ? roster : []
who_rows     = who.is_a?(Array) ? who : []
roster_names = roster_rows.map { |r| r['display_name'] }
no_addresses = !raw_roster.include?(EMAIL) && !raw_roster.include?('@')
named        = roster_rows.length >= 2 &&
               roster_names.all? { |n| n.is_a?(String) && !n.strip.empty? }
recognisable = (roster_names & %w[Alice Bob]).sort == %w[Alice Bob]

# Headless accounts get a distinct opaque `member-<12 hex>`; re-invite so the roster has two.
_, rejoin = post_json('/kiosk/invite', { list_id: list_id }, WIRE.dpop(owner[:token], owner[:key]))
post_json('/kiosk/accept_invite', { code: rejoin['code'] }, WIRE.dpop(outsider[:token], outsider[:key]))
rc_headless, headless = get_json('/kiosk/list_members', { list_id: list_id }, WIRE.dpop(owner[:token], owner[:key]))
headless_names = (headless.is_a?(Array) ? headless : []).map { |r| r['display_name'] }
opaque_ok = headless_names.length >= 2 &&
            headless_names.all? { |n| n.to_s.match?(/\Amember-[0-9a-f]{12}\z/) } &&
            headless_names.uniq.length == headless_names.length

BATTERY.record('NoLoginAddressOnTheRoster',
               pii_rc_link == 201 && pii_rc_claim == 204 && pii_rc_token == 200 &&
               rc_mine == 200 && rc_roster == 200 && rc_who == 200 && rc_headless == 200 &&
               no_addresses && named && recognisable && opaque_ok,
               "link=#{pii_rc_link} claim=#{pii_rc_claim} token=#{pii_rc_token}; " \
               "list_members on the seeded household as Alice's assistant → #{rc_roster}, " \
               "#{roster_rows.length} rows named #{roster_names.inspect}; whoami → #{rc_who} " \
               "#{who_rows.first&.fetch('display_name', nil).inspect}; account addresses in " \
               "roster+whoami body: #{no_addresses ? 'none' : 'FOUND'}; headless roster → " \
               "#{rc_headless} #{headless_names.inspect} " \
               '(want no address anywhere, every row a non-empty display_name, the seeded ' \
               'household reading as Alice+Bob, and each headless account an opaque ' \
               '`member-<12 hex>`)')

# Sign-up's chosen name, not the address, is what the Members block shows. Its own cookie jar.
signup       = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)
chosen_name  = 'Cassie Housemate'
signup_email = "cassie-#{SecureRandom.hex(4)}@example.com"
signup_form  = signup.get_html('/users/sign_up')
signup_res   = signup.post_form('/users',
                                'authenticity_token' => signup.csrf_token(signup_form.body),
                                'user[display_name]' => chosen_name,
                                'user[email]' => signup_email,
                                'user[password]' => PASSWORD,
                                'user[password_confirmation]' => PASSWORD)
lists_page   = signup.get_html('/lists')
# Per-form CSRF: take the token from the new-list form, not the sign-out button above it.
new_list_form = lists_page.body.to_s[%r{<form[^>]*action="/lists"[^>]*>.*?</form>}m].to_s
create_res   = signup.post_form('/lists',
                                'authenticity_token' => signup.csrf_token(new_list_form),
                                'title' => "Cassie's shelf")
list_page    = signup.get_html(create_res['location'].to_s)
members_html = list_page.body.to_s[%r{<h2>Members</h2>.*?</ul>}m].to_s

BATTERY.record('ChosenNameNeverTheAddress',
               signup_form.code.to_i == 200 && [302, 303].include?(signup_res.code.to_i) &&
               [302, 303].include?(create_res.code.to_i) && list_page.code.to_i == 200 &&
               members_html.include?(chosen_name) && !members_html.include?('@'),
               "sign-up form → #{signup_form.code}, sign-up → #{signup_res.code}, " \
               "create list → #{create_res.code}, list page → #{list_page.code}; members block " \
               "#{members_html.gsub(/\s+/, ' ').strip.inspect} " \
               "(want the chosen name #{chosen_name.inspect} there and no address in it)")

# Shared kiosk-redteam beat; this origin declares a role, so a skip is a breach.
BATTERY.scenario(
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  client: Kiosk::TestHelpers::Assistant.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer]),
  on_skip: :breach
)

exit BATTERY.report!
