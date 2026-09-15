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
#
# Two agents register with real keys → real Kiosk JWTs (UUID agent_ids), so the
# attribution column is a genuine kiosk.agents.id.
#
# Usage (invoked by rake demo:collab):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/collab_flow.rb
# Prints ONE JSON line on stdout; non-zero exit on any hard transport failure.

require "json"
require "jwt"
require "time"
require "net/http"
require "kiosk/redteam/wire"
require "uri"
require "openssl"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# THE 0.4 WIRE. An action is `POST <mount>/<action-name>` with its arguments as
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
  { token: reg.fetch("access_token"), agent_id: reg.fetch("agent_id") }
end

results = {}

# ── Alice's agent: register → create "Hike" (owner) → add a todo → invite ─────
alice = register_agent("alice")
results[:alice_agent_id] = alice[:agent_id]

rc, created = post_json("/kiosk/create_list", { title: "Hike" }, bearer(alice[:token]))
abort "create_list failed (#{rc}): #{JSON.generate(created)}" unless rc == 200
list_id = created["list_id"]
results[:list_id] = list_id
STDERR.puts "  Alice's agent created list #{list_id}"

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

rc, inv = post_json("/kiosk/invite", { list_id: list_id }, bearer(alice[:token]))
abort "invite failed (#{rc}): #{JSON.generate(inv)}" unless rc == 200
code = inv["code"]
results[:invite_returned_code] = !code.to_s.empty?
STDERR.puts "  Alice's agent minted an invite code"

# ── Bob's agent: register → accept_invite (member) → add a todo ───────────────
bob = register_agent("bob")
results[:bob_agent_id] = bob[:agent_id]

rc, acc = post_json("/kiosk/accept_invite", { code: code }, bearer(bob[:token]))
results[:accept_status]  = rc
results[:accept_joined]  = acc["joined"] == true
results[:accept_list_id] = acc["list_id"]
abort "accept_invite failed (#{rc}): #{JSON.generate(acc)}" unless rc == 200
STDERR.puts "  Bob's agent accepted the invite and joined list #{results[:accept_list_id]}"

rc, btodo = post_json("/kiosk/add_todo",
                      { list_id: list_id, title: "Bring tent" },
                      reader(bob[:token], BOB_TZ))
abort "bob add_todo failed (#{rc}): #{JSON.generate(btodo)}" unless rc == 200
bob_todo_id = btodo["todo_id"]

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

puts JSON.generate(results)
