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
#   4  Forged account_id arg on Mallory's create_list is IGNORED — the created
#      list's DB account_id == Mallory (verified via psql in the rake task).
#   5  A FOREIGN/used invite code — Mallory replays the Member's already-used
#      code → 403 (single-use). A garbage code → 403.
#   6  POSITIVE CONTROL: the Member (genuinely invited) DOES see the list in
#      my_lists and CAN read its todos (200).
#   7  After remove_member cuts the Member, their next list_todos → 403
#      (access gone instantly).
#
# Usage:
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby isolation_flow.rb
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

def register_agent(label)
  key = OpenSSL::PKey::RSA.generate(2048)
  pem = key.public_key.to_pem
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "#{label} challenge failed (#{rc})" unless rc == 200
  pop = JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
  rc, reg = post_json("/kiosk/auth/register", { public_key: pem, signed: pop })
  abort "#{label} register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  { token: reg.fetch("access_token"), agent_id: reg.fetch("agent_id"), user_id: reg.fetch("user_id") }
end

results = {}

owner   = register_agent("owner")
member  = register_agent("member")
mallory = register_agent("mallory")
results[:mallory_user_id] = mallory[:user_id]

# Owner creates a private list.
rc, created = post_json("/kiosk/run", { name: "create_list", title: "Private" }, bearer(owner[:token]))
abort "create_list failed (#{rc}): #{JSON.generate(created)}" unless rc == 200
list_id = created.dig("value", "list_id")
results[:list_id] = list_id

# Owner mints an invite; the Member (genuine) accepts it (positive control).
rc, inv = post_json("/kiosk/run", { name: "invite", list_id: list_id }, bearer(owner[:token]))
abort "invite failed (#{rc})" unless rc == 200
member_code = inv.dig("value", "code")
rc, acc = post_json("/kiosk/run", { name: "accept_invite", code: member_code }, bearer(member[:token]))
abort "member accept failed (#{rc}): #{JSON.generate(acc)}" unless rc == 200

# ── Assertion 1: Mallory's my_lists is empty ────────────────────────────────
rc, m_lists = post_json("/kiosk/query", { name: "my_lists" }, bearer(mallory[:token]))
results[:mallory_my_lists_empty] = rc == 200 && (m_lists["rows"] || []).empty?

# ── Assertions 2 & 3: Mallory non-member reads → 403 ────────────────────────
rc, = post_json("/kiosk/query", { name: "list_todos", list_id: list_id }, bearer(mallory[:token]))
results[:mallory_list_todos] = rc
rc, = post_json("/kiosk/query", { name: "list_members", list_id: list_id }, bearer(mallory[:token]))
results[:mallory_list_members] = rc

# ── Assertion 4: forged account_id on Mallory's create_list is IGNORED ──────
rc, forged = post_json("/kiosk/run",
                       { name: "create_list", title: "Forged owner test", account_id: owner[:user_id] },
                       bearer(mallory[:token]))
abort "mallory forged create failed (#{rc})" unless rc == 200
results[:forged_list_id] = forged.dig("value", "list_id")

# ── Assertion 5: replayed (used) invite code + garbage code → 403 ───────────
rc, = post_json("/kiosk/run", { name: "accept_invite", code: member_code }, bearer(mallory[:token]))
results[:mallory_replay_used_code] = rc
rc, = post_json("/kiosk/run", { name: "accept_invite", code: "not-a-real-code" }, bearer(mallory[:token]))
results[:mallory_garbage_code] = rc

# ── Assertion 6: POSITIVE CONTROL — the Member DOES see + read the list ─────
rc, mem_lists = post_json("/kiosk/query", { name: "my_lists" }, bearer(member[:token]))
results[:member_sees_list] = rc == 200 && (mem_lists["rows"] || []).any? { |r| r["list_id"] == list_id }
rc, = post_json("/kiosk/query", { name: "list_todos", list_id: list_id }, bearer(member[:token]))
results[:member_reads_todos] = rc

# ── Assertion 7: after remove_member, the Member's next read → 403 ──────────
rc, rem = post_json("/kiosk/run",
                    { name: "remove_member", list_id: list_id, account_id: member[:user_id] },
                    bearer(owner[:token]))
results[:remove_member_status] = rc
abort "remove_member failed (#{rc}): #{JSON.generate(rem)}" unless rc == 200
rc, = post_json("/kiosk/query", { name: "list_todos", list_id: list_id }, bearer(member[:token]))
results[:member_after_removal] = rc

puts JSON.generate(results)
