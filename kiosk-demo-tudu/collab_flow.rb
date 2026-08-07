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
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby collab_flow.rb
# Prints ONE JSON line on stdout; non-zero exit on any hard transport failure.

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, headers = {})
  uri = URI("#{SERVER}#{path}")
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

require_relative "lib/equihash_register"

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

rc, created = post_json("/kiosk/run", { name: "create_list", title: "Hike" }, bearer(alice[:token]))
abort "create_list failed (#{rc}): #{JSON.generate(created)}" unless rc == 200
list_id = created.dig("value", "list_id")
results[:list_id] = list_id
STDERR.puts "  Alice's agent created list #{list_id}"

rc, atodo = post_json("/kiosk/run",
                      { name: "add_todo", list_id: list_id, title: "Book campsite" },
                      bearer(alice[:token]))
abort "alice add_todo failed (#{rc}): #{JSON.generate(atodo)}" unless rc == 200
alice_todo_id = atodo.dig("value", "todo_id")

rc, inv = post_json("/kiosk/run", { name: "invite", list_id: list_id }, bearer(alice[:token]))
abort "invite failed (#{rc}): #{JSON.generate(inv)}" unless rc == 200
code = inv.dig("value", "code")
results[:invite_returned_code] = !code.to_s.empty?
STDERR.puts "  Alice's agent minted an invite code"

# ── Bob's agent: register → accept_invite (member) → add a todo ───────────────
bob = register_agent("bob")
results[:bob_agent_id] = bob[:agent_id]

rc, acc = post_json("/kiosk/run", { name: "accept_invite", code: code }, bearer(bob[:token]))
results[:accept_status]  = rc
results[:accept_joined]  = acc.dig("value", "joined") == true
results[:accept_list_id] = acc.dig("value", "list_id")
abort "accept_invite failed (#{rc}): #{JSON.generate(acc)}" unless rc == 200
STDERR.puts "  Bob's agent accepted the invite and joined list #{results[:accept_list_id]}"

rc, btodo = post_json("/kiosk/run",
                      { name: "add_todo", list_id: list_id, title: "Bring tent" },
                      bearer(bob[:token]))
abort "bob add_todo failed (#{rc}): #{JSON.generate(btodo)}" unless rc == 200
bob_todo_id = btodo.dig("value", "todo_id")

# ── Assert the shared world ──────────────────────────────────────────────────
rc, a_lists = post_json("/kiosk/query", { name: "my_lists" }, bearer(alice[:token]))
results[:alice_sees_hike] = rc == 200 && (a_lists["rows"] || []).any? { |r| r["list_id"] == list_id && r["role"] == "owner" }
rc, b_lists = post_json("/kiosk/query", { name: "my_lists" }, bearer(bob[:token]))
results[:bob_sees_hike] = rc == 200 && (b_lists["rows"] || []).any? { |r| r["list_id"] == list_id && r["role"] == "member" }

rc, todos = post_json("/kiosk/query", { name: "list_todos", list_id: list_id }, bearer(bob[:token]))
rows = todos["rows"] || []
results[:shared_todo_count] = rows.size
# Attribution: each todo's created_by_agent_id is the agent that added it.
alice_row = rows.find { |r| r["todo_id"] == alice_todo_id }
bob_row   = rows.find { |r| r["todo_id"] == bob_todo_id }
results[:alice_todo_attributed] = alice_row && alice_row["created_by_agent_id"] == alice[:agent_id]
results[:bob_todo_attributed]   = bob_row   && bob_row["created_by_agent_id"]   == bob[:agent_id]

rc, members = post_json("/kiosk/query", { name: "list_members", list_id: list_id }, bearer(alice[:token]))
mrows = members["rows"] || []
results[:member_count]  = mrows.size
results[:has_owner]     = mrows.any? { |m| m["role"] == "owner" }
results[:has_member]    = mrows.any? { |m| m["role"] == "member" }

puts JSON.generate(results)
