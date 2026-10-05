# frozen_string_literal: true

# tudu collaboration driver — the happy path that proves MEMBERSHIP-BASED
# many-to-many access and AGENT→AGENT collaboration expressed entirely at the
# app layer (no spec change):
#
#   Alice's agent registers (headless account via PoP), creates the "Hike" list
#   (becomes its owner), adds a todo, and mints an INVITE code.
#   Bob's agent registers (a DIFFERENT headless account), ACCEPTS the invite
#   (joins as a member), and adds his own todo.
#
# Then it asserts the shared world:
#   - both agents' my_lists include "Hike" (Bob reaches a list he does NOT own)
#   - list_todos shows BOTH todos with per-agent ATTRIBUTION
#     (each todo's created_by_agent_id is the agent that added it)
#   - list_members shows two members: Alice (owner) + Bob (member)
#   - over <endpoint>/events, Alice's assistant is told of Bob joining, of
#     Bob's todo (replayed by `since` after a disconnect), and of Bob's
#     removal, which withdraws Bob's own subscription (`reach_revoked`)
#
# Two agents register with real keys → real Kiosk JWTs (UUID agent_ids), so the
# attribution column is a genuine kiosk.agents.id.
#
# Usage (invoked by rake check:collab):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/collab_flow.rb
# Prints ONE JSON line on stdout; non-zero exit on any hard transport failure.

require "json"
require "jwt"
require "time"
require "net/http"
require "kiosk/redteam/wire"
require "kiosk/redteam/event_stream"
require "json_schemer"
require "uri"
require "openssl"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# THE WIRE. An action is `POST <mount>/<action-name>` with its arguments as
# the JSON body; a query is `GET <mount>/<query-name>` with its arguments in the
# query string. There is no `name` field and no /query or /run endpoint. A
# success body IS the result — a bare array from a non-paginating query, the
# action's own object from an action — and an error is an RFC 9457 problem
# document whose branch point is the top-level `code`.
def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Kiosk::Redteam::Wire.http_for(uri).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, params = {}, headers = {})
  uri = URI("#{SERVER}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Kiosk::Redteam::Wire.http_for(uri).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

# ── THE TWO READERS' CLOCKS ─────────────────────────────────────────────────
#
# A deadline on a SHARED list is the sharpest case this wire has: "tomorrow at
# two" is said by one person and read by another, and there is no single
# wall-clock string that is correct for both. So the assistant resolves it on
# the clock of the human who SAID it, sends one absolute instant, and each
# reader declares its OWN clock on the read -- `Kiosk-Timezone`, an IANA name,
# never the machine's own zone.
ALICE_TZ = "Europe/Istanbul"
BOB_TZ   = "America/New_York"

def reader(token, tz) = bearer(token).merge("Kiosk-Timezone" => tz)

require_relative "equihash_register"

# The equihash_register helper injects full-URL get/post callables (tudu's own
# post_json/get_json take a path), so wrap them to accept a full URL.
GET_URL  = ->(url)                 { get_json(url.delete_prefix(SERVER)) }
POST_URL = ->(url, body, hdrs = {}) { post_json(url.delete_prefix(SERVER), body, hdrs) }

# Register a fresh agent (headless account) via PoP, solving the register PoW
# transparently (register is uniformly tolled) → { token, agent_id }. The
# _label is kept for call-site readability; the helper aborts with detail on failure.
def register_agent(_label)
  _key, reg = equihash_register(server: SERVER, issuer: ISSUER, get_json: GET_URL, post_json: POST_URL)
  { token: reg.fetch("access_token"), agent_id: reg.fetch("agent_id"), user_id: reg.fetch("user_id") }
end

results = {}

# ── Alice's agent: register → create "Hike" (owner) → add a todo → invite ─────
alice = register_agent("alice")

rc, created = post_json("/kiosk/create_list", { title: "Hike" }, bearer(alice[:token]))
abort "create_list failed (#{rc}): #{JSON.generate(created)}" unless rc == 200
list_id = created["list_id"]
results[:list_id] = list_id
STDERR.puts "  Alice's agent created list #{list_id}"

# Alice's assistant holds the list's two topics, plus `todo` with no subject.
def stream_for(who) = Kiosk::Redteam::EventStream.new(base_url: SERVER, token: who[:token])

alice_live = stream_for(alice)
alice_live.subscribe("todo", subject: list_id)
alice_live.subscribe("list_membership", subject: list_id)
alice_any = stream_for(alice)
alice_any.subscribe("todo")

# ALICE'S HUMAN SAID «tomorrow at two». Her assistant resolves that on HER
# clock, before it reaches the wire, and sends the instant it resolved to.
DUE_AT = (Time.now.utc + (36 * 3600)).getlocal("+03:00").strftime("%Y-%m-%dT14:00:00%:z")
rc, atodo = post_json("/kiosk/add_todo",
                      { list_id: list_id, title: "Book campsite", due_at: DUE_AT },
                      reader(alice[:token], ALICE_TZ))
abort "alice add_todo failed (#{rc}): #{JSON.generate(atodo)}" unless rc == 200
alice_todo_id = atodo["todo_id"]

# A ZONELESS DEADLINE IS REFUSED, not completed. It is the one value that would
# mean two different moments to the two readers with nothing on the wire to say
# so, and completing it here would pick one of them silently.
rc_zoneless, zless = post_json("/kiosk/add_todo",
                               { list_id: list_id, title: "no zone", due_at: "2026-09-08T14:00:00" },
                               reader(alice[:token], ALICE_TZ))
results[:zoneless_due_status] = rc_zoneless
results[:zoneless_due_code]   = zless["code"]
# THE SENTENCE, not only the status: a 400/`bad_request` is what every typed
# refusal on this wire carries, so those two alone do not say WHICH argument was
# refused. `due_at` is declared `format: "date-time"`, so the argument
# validation answers first and its detail names the argument.
results[:zoneless_due_detail] = zless["detail"].to_s

rc, inv = post_json("/kiosk/invite", { list_id: list_id }, bearer(alice[:token]))
abort "invite failed (#{rc}): #{JSON.generate(inv)}" unless rc == 200
code = inv["code"]
results[:invite_returned_code] = !code.to_s.empty?
STDERR.puts "  Alice's agent minted an invite code"

# ── Bob's agent: register → accept_invite (member) → add a todo ───────────────
bob = register_agent("bob")

rc, acc = post_json("/kiosk/accept_invite", { code: code }, bearer(bob[:token]))
results[:accept_joined]  = acc["joined"] == true
results[:accept_list_id] = acc["list_id"]
abort "accept_invite failed (#{rc}): #{JSON.generate(acc)}" unless rc == 200
STDERR.puts "  Bob's agent accepted the invite and joined list #{results[:accept_list_id]}"

joined = alice_live.await { |e| e["topic"] == "list_membership" && e.dig("data", "action") == "joined" }
results[:event_joined_live] = joined.dig("data", "account_id") == bob[:user_id]
results[:event_own_todo_live] =
  alice_live.events.any? { |e| e["topic"] == "todo" && e.dig("data", "todo_id") == alice_todo_id }

# Alice's assistant goes away, holding the newest id it saw as its cursor.
cursor = alice_live.events.map { |e| e["id"] }.max
alice_live.close

bob_stream = stream_for(bob)
bob_stream.subscribe("todo", subject: list_id)

rc, btodo = post_json("/kiosk/add_todo",
                      { list_id: list_id, title: "Bring tent" },
                      reader(bob[:token], BOB_TZ))
abort "bob add_todo failed (#{rc}): #{JSON.generate(btodo)}" unless rc == 200
bob_todo_id = btodo["todo_id"]

# Back, with `since`: Bob's todo arrives as a replay, and nothing at or before the cursor.
alice_back = stream_for(alice)
alice_back.subscribe("todo", subject: list_id, since: cursor)
alice_back.subscribe("list_membership", subject: list_id)
bobs = ->(e) { e["topic"] == "todo" && e.dig("data", "todo_id") == bob_todo_id }
results[:event_replayed_since] = alice_back.await(&bobs).dig("data", "action") == "added"
results[:event_replay_after_cursor] = alice_back.events.all? { |e| e["id"] > cursor }
results[:event_subjectless_live] = !alice_any.await(&bobs).nil?

# ── Assert the shared world ──────────────────────────────────────────────────
rc, a_lists = get_json("/kiosk/my_lists", {}, bearer(alice[:token]))
results[:alice_sees_hike] = rc == 200 && Array(a_lists).any? { |r| r["list_id"] == list_id && r["role"] == "owner" }
rc, b_lists = get_json("/kiosk/my_lists", {}, bearer(bob[:token]))
results[:bob_sees_hike] = rc == 200 && Array(b_lists).any? { |r| r["list_id"] == list_id && r["role"] == "member" }

rc, todos = get_json("/kiosk/list_todos", { list_id: list_id }, reader(bob[:token], BOB_TZ))
rows = Array(todos)
results[:shared_todo_count] = rows.size
# Attribution: each todo's created_by_agent_id is the agent that added it.
alice_row = rows.find { |r| r["todo_id"] == alice_todo_id }
bob_row   = rows.find { |r| r["todo_id"] == bob_todo_id }
results[:alice_todo_attributed] = alice_row && alice_row["created_by_agent_id"] == alice[:agent_id]
results[:bob_todo_attributed]   = bob_row   && bob_row["created_by_agent_id"]   == bob[:agent_id]

# ── ONE INSTANT, TWO CLOCKS, AND THE ROW SAYS WHICH ─────────────────────────
#
# The same todo, read by the two members of one list, each declaring their own
# zone. The wall clocks DIFFER and the moment does NOT: that is the whole of
# the viewer-relative rule, and it is the reason the column is an instant
# rather than a local time.
rc, a_todos = get_json("/kiosk/list_todos", { list_id: list_id }, reader(alice[:token], ALICE_TZ))
a_row = Array(a_todos).find { |r| r["todo_id"] == alice_todo_id }
b_row = alice_row
results[:alice_due_zone]  = a_row && a_row["timezone"]
results[:bob_due_zone]    = b_row && b_row["timezone"]
results[:due_zones_differ] = !!(a_row && b_row && a_row["timezone"] != b_row["timezone"])
results[:due_labels_differ] = !!(a_row && b_row && a_row["due_label"] != b_row["due_label"])
results[:due_same_instant] = !!(a_row && b_row &&
                                Time.iso8601(a_row["due_at"]).to_i == Time.iso8601(b_row["due_at"]).to_i)
results[:due_label_names_zone] = !!(a_row && a_row["due_label"].to_s.include?(ALICE_TZ))
# A caller that declares NOTHING gets the household's own clock, and the row
# says so -- a declared default rather than an accident.
rc, n_todos = get_json("/kiosk/list_todos", { list_id: list_id }, bearer(alice[:token]))
n_row = Array(n_todos).find { |r| r["todo_id"] == alice_todo_id }
results[:no_header_zone] = n_row && n_row["timezone"]

rc, members = get_json("/kiosk/list_members", { list_id: list_id }, bearer(alice[:token]))
mrows = Array(members)
results[:member_count]  = mrows.size
results[:has_owner]     = mrows.any? { |m| m["role"] == "owner" }
results[:has_member]    = mrows.any? { |m| m["role"] == "member" }

# ── Bob is removed: Alice is told, and Bob's standing subscription is withdrawn ──
rc, = post_json("/kiosk/remove_member", { list_id: list_id, account_id: bob[:user_id] }, bearer(alice[:token]))
abort "remove_member failed (#{rc})" unless rc == 200
removed = alice_back.await { |e| e["topic"] == "list_membership" && e.dig("data", "action") == "removed" }
results[:event_removed_live] = removed.dig("data", "account_id") == bob[:user_id]
revoked = bob_stream.await_message(timeout: 45) { |m| m["type"] == "unsubscribed" }
results[:event_reach_revoked] = revoked == { "type" => "unsubscribed", "topic" => "todo", "reason" => "reach_revoked" }

# Every delivered `data` against the `payload_schema` this origin serves for its topic.
_rc, served = get_json("/kiosk/schema")
schemers = Array(served["events"]).to_h do |t|
  [t["name"], JSONSchemer.schema(t["payload_schema"], meta_schema: "https://json-schema.org/draft/2020-12/schema")]
end
delivered = [alice_live, alice_any, alice_back, bob_stream].flat_map(&:events)
results[:event_topics_delivered] = delivered.map { |e| e["topic"] }.uniq.sort
results[:event_payload_errors] = delivered.flat_map do |e|
  schemers.fetch(e["topic"]).validate(e["data"]).map { |v| "#{e["topic"]}: #{v["error"]}" }
end
[alice_any, alice_back, bob_stream].each(&:close)

puts JSON.generate(results)
