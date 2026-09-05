# frozen_string_literal: true

# Adversarial membership-isolation driver for tudu.
#
# Unlike philslist's owner-scoped board, tudu's access is MEMBERSHIP-based
# many-to-many. This flow proves a third principal (Mallory) is walled out of a
# list she is not a member of, with a genuine-member POSITIVE CONTROL so the
# exclusions aren't vacuous.
#
# Three registered agents (real Kiosk keys → UUID agent_ids/accounts):
#   Owner   — creates the "Private" list (owner membership).
#   Member  — accepts a genuine invite (positive control: a member DOES see it).
#   Mallory — never invited (the adversary).
#
# Assertions (parsed by rake demo:isolation):
#   1  Mallory's my_lists is EMPTY (she is a member of nothing).
#   2  Mallory list_todos on the owner's list → 403 (non-member read denial).
#   3  Mallory list_members on the owner's list → 403.
#   4  Forged account_id arg on Mallory's create_list is REFUSED at the declared
#      input contract (400 bad_request naming account_id), and Mallory's
#      legitimate list is owned by Mallory in the DB (verified via psql in the
#      rake task) — the principal comes from the token, and is not an input.
#   5  A FOREIGN/used invite code — Mallory replays the Member's already-used
#      code → 403 (single-use). A garbage code → 403.
#   6  POSITIVE CONTROL: the Member (genuinely invited) DOES see the list in
#      my_lists and CAN read its todos (200).
#   7  After remove_member cuts the Member, their next list_todos → 403
#      (access gone instantly).
#
# Usage:
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/isolation_flow.rb
# Prints ONE JSON line on stdout; non-zero exit on any hard transport failure.

require "json"
require "jwt"
require "net/http"
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
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, params = {}, headers = {})
  uri = URI("#{SERVER}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

require_relative "equihash_register"

# The equihash_register helper injects full-URL get/post callables (tudu's own
# post_json/get_json take a path), so wrap them to accept a full URL.
GET_URL  = ->(url)                 { get_json(url.delete_prefix(SERVER)) }
POST_URL = ->(url, body, hdrs = {}) { post_json(url.delete_prefix(SERVER), body, hdrs) }

# Register a fresh agent, solving the register PoW transparently (register is
# uniformly tolled). The helper aborts with detail on failure.
def register_agent(_label)
  _key, reg = equihash_register(server: SERVER, issuer: ISSUER, get_json: GET_URL, post_json: POST_URL)
  { token: reg.fetch("access_token"), agent_id: reg.fetch("agent_id"), user_id: reg.fetch("user_id") }
end

results = {}

owner   = register_agent("owner")
member  = register_agent("member")
mallory = register_agent("mallory")
results[:mallory_user_id] = mallory[:user_id]

# Owner creates a private list.
rc, created = post_json("/kiosk/create_list", { title: "Private" }, bearer(owner[:token]))
abort "create_list failed (#{rc}): #{JSON.generate(created)}" unless rc == 200
list_id = created["list_id"]
results[:list_id] = list_id

# Owner mints an invite; the Member (genuine) accepts it (positive control).
rc, inv = post_json("/kiosk/invite", { list_id: list_id }, bearer(owner[:token]))
abort "invite failed (#{rc})" unless rc == 200
member_code = inv["code"]
rc, acc = post_json("/kiosk/accept_invite", { code: member_code }, bearer(member[:token]))
abort "member accept failed (#{rc}): #{JSON.generate(acc)}" unless rc == 200

# ── Assertion 1: Mallory's my_lists is empty ────────────────────────────────
rc, m_lists = get_json("/kiosk/my_lists", {}, bearer(mallory[:token]))
results[:mallory_my_lists_empty] = rc == 200 && Array(m_lists).empty?

# ── Assertions 2 & 3: Mallory non-member reads → 403 ────────────────────────
rc, = get_json("/kiosk/list_todos", { list_id: list_id }, bearer(mallory[:token]))
results[:mallory_list_todos] = rc
rc, = get_json("/kiosk/list_members", { list_id: list_id }, bearer(mallory[:token]))
results[:mallory_list_members] = rc

# ── Assertion 4: the principal is NOT an input ──────────────────────────────
#
# Mallory's token identifies Mallory; the forged arg supplies the owner's UUID.
# On the 0.4 wire this is REFUSED before the handler runs: `create_list`
# publishes `additionalProperties: false` and declares only `title` — the
# principal is not one of its inputs — so the declared input contract answers a
# typed 400 naming the parameter. (Through 0.3 the argument was accepted and
# silently ignored; refusing it is the stricter answer and the one the published
# contract requires.)
forged_rc, forged = post_json("/kiosk/create_list",
                              { title: "Forged owner test", account_id: owner[:user_id] },
                              bearer(mallory[:token]))
results[:forged_refusal] = [forged_rc, forged["code"], forged["detail"]]

# And the second half, which the refusal does not by itself prove: ownership is
# taken from the AUTHENTICATED identity. Mallory creates a list legitimately;
# the rake task reads the row back and asserts account_id == Mallory.
rc, legit = post_json("/kiosk/create_list", { title: "Owner-from-token test" }, bearer(mallory[:token]))
abort "mallory create_list failed (#{rc}): #{JSON.generate(legit)}" unless rc == 200
results[:owner_probe_list_id] = legit["list_id"]

# ── Assertion 5: replayed (used) invite code + garbage code → 403 ───────────
rc, = post_json("/kiosk/accept_invite", { code: member_code }, bearer(mallory[:token]))
results[:mallory_replay_used_code] = rc
rc, = post_json("/kiosk/accept_invite", { code: "not-a-real-code" }, bearer(mallory[:token]))
results[:mallory_garbage_code] = rc

# ── Assertion 6: POSITIVE CONTROL — the Member DOES see + read the list ─────
rc, mem_lists = get_json("/kiosk/my_lists", {}, bearer(member[:token]))
results[:member_sees_list] = rc == 200 && Array(mem_lists).any? { |r| r["list_id"] == list_id }
rc, = get_json("/kiosk/list_todos", { list_id: list_id }, bearer(member[:token]))
results[:member_reads_todos] = rc

# ── Assertion 8: the DECLARED reach ─────────────────────────────────────────
#
# §7.2's default is absolute — a verb touches only the calling principal's rows
# — and tudu departs from it on purpose: a member reads a list somebody else
# owns. The spec requires that departure to be PUBLISHED, so an assistant
# and a sweep can tell collaboration from a scoping bug. Two halves:
#
#   (a) what the catalog SAYS: my_lists / list_todos / list_members publish
#       `consented`, whoami publishes `principal`. Read with NO token, the way
#       any caller reads the unauthenticated catalog.
#   (b) what the wire DOES: every query the catalog publishes as `principal`
#       and that takes no required argument is called AS THE MEMBER — who
#       legitimately reaches the owner's list — and none of the answers may
#       carry that list's id. This runs BEFORE Assertion 7 cuts the Member off,
#       because after that there is nothing left to leak and the probe would
#       pass for the wrong reason. Delete `reach :consented` from my_lists and
#       it joins this probe set carrying the owner's list under a `principal`
#       claim, which is the defect this beat catches, on the live wire.
rc, catalog = get_json("/kiosk/schema")
abort "schema failed (#{rc}): #{JSON.generate(catalog)}" unless rc == 200
results[:reach_by_verb] = (Array(catalog["queries"]) + Array(catalog["actions"]))
                          .to_h { |d| [d["name"], d["reach"]] }

results[:principal_probe] = Array(catalog["queries"]).filter_map { |d|
  next unless (d["reach"] || "principal") == "principal"
  next unless Array(d.dig("input_schema", "required")).empty?

  prc, prows = get_json("/kiosk/#{d['name']}", {}, bearer(member[:token]))
  [d["name"], prc, JSON.generate(prows)]
}

# ── Assertion 7: after remove_member, the Member's next read → 403 ──────────
rc, rem = post_json("/kiosk/remove_member",
                    { list_id: list_id, account_id: member[:user_id] },
                    bearer(owner[:token]))
results[:remove_member_status] = rc
abort "remove_member failed (#{rc}): #{JSON.generate(rem)}" unless rc == 200
rc, = get_json("/kiosk/list_todos", { list_id: list_id }, bearer(member[:token]))
results[:member_after_removal] = rc

puts JSON.generate(results)
