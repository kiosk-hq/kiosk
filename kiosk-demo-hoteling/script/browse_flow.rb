# frozen_string_literal: true

# Hoteling browse-heavy PoW driver (priced pagination).
#
# Hotel search is legitimately browse-heavy — an assistant compares many
# options. This vertical does not treat that as suspicion; it prices DEPTH:
# the first few queries are free, then each extra one costs proof-of-work,
# escalating with the query rate. This driver registers once, then
# runs a burst of `properties` queries and records, per query, how many proofs
# the provider demanded — showing the free-then-priced curve.
#
# It then drives ONE ACTION (`reserve_room`) through the same gate, because the
# policy hook's write kind is `:run` and NOT the `:action` an operator declares
# above the handler. A policy that branched on `:action` would return
# nil forever, silently, and the toll would never apply to a write — so the
# 402 this driver expects on the un-proofed `reserve_room` is what proves the
# branch fires at all.
#
# Usage (invoked by rake demo:browse — needs the server with KIOSK_POW_BROWSE_DEMO=1):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/browse_flow.rb
# Requires: python3 with numpy.

require "json"
require "jwt"
require "net/http"
require "kiosk/redteam/wire"
require "uri"
require "openssl"
require "open3"
require "securerandom"

SERVER  = ENV.fetch("SERVER_URL")
ISSUER  = ENV.fetch("KIOSK_ISSUER")
BROWSES = Integer(ENV.fetch("BROWSES", "7"))

# equihash_solve / equihash_register come from the shared helper; the solver
# location is Kiosk::Pow::Equihash.solver_path, owned by the gem.
require_relative "equihash_register"

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Kiosk::Redteam::Wire.http_for(uri).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Kiosk::Redteam::Wire.http_for(uri).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Register (register PoW solved transparently) ──────────────────────────────
_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
token = reg.fetch("access_token")
auth  = { "Authorization" => "Bearer #{token}" }

# ── Burst of `properties` browses; record proofs demanded per browse ────────
#
# THE 0.4 WIRE: a query is `GET <endpoint>/<query-name>`. `properties` takes no
# arguments, so the URL is the whole call — there is no `name` field and no
# `POST /kiosk/query` to send it to.
BROWSE_URL = "#{SERVER}/kiosk/properties"
curve = []
last_props = []
BROWSES.times do |i|
  rc, resp = get_json(BROWSE_URL, auth)
  if rc == 402
    # The 402 is an RFC 9457 problem document: `challenges` is a TOP-LEVEL
    # extension member, not nested under an `error` object.
    challenges = resp["challenges"]
    abort "browse #{i}: 402 without challenges[]" unless challenges.is_a?(Array) && challenges.any?
    proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
    # PoW proof rides in the Kiosk-PoW request header as raw JSON,
    # not the body — the REQUEST LINE and the arguments stay byte-identical so
    # the request fingerprint (`SHA256("GET properties\n{}")`) matches on retry.
    rc, resp = get_json(BROWSE_URL, auth.merge("Kiosk-PoW" => JSON.generate(proofs)))
    curve << proofs.size
  else
    curve << 0
  end
  abort "browse #{i} not served (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  last_props = Array(resp)
  $stderr.puts "  [browse] query #{i + 1}: #{curve.last} proof(s), served"
end

# ── THE WRITE TOLL — an action reaches the policy as `:run` ─────────────────
#
# The policy hook receives one of `Kiosk::Server::Executor::VERBS` —
# `%i[query run pay]` — while what an operator DECLARES above the handler is
# `kind :query` / `kind :action`. `:query` is the one word spelled the same in
# both vocabularies, so a policy that branches only on it looks correct and a
# policy that branches on `:action` traps SILENTLY: `challenge_for` returning
# nil is the ordinary «do not toll this one» answer, so the write toll simply
# never applies and nothing anywhere says so.
#
# So this driver EXERCISES the write branch rather than trusting it. The
# assertion that matters is the FIRST response to `reserve_room`: a 402 with
# challenges means `:run` reached the policy; a 200 means the branch never
# fired, which is exactly what a `verb == :action` policy produces.
require "date"

# One call, retried once with proofs when the origin answers 402. The retry is
# byte-identical except for the `Kiosk-PoW` header — same method, same verb,
# same arguments — because that is what the request fingerprint the challenge
# binds to covers.
def with_pow(label)
  rc, resp = yield({})
  return [rc, resp, 0] unless rc == 402

  challenges = resp["challenges"]
  abort "#{label}: 402 without challenges[]" unless challenges.is_a?(Array) && challenges.any?
  proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
  rc, resp = yield({ "Kiosk-PoW" => JSON.generate(proofs) })
  [rc, resp, proofs.size]
end

abort "browse burst returned no properties to reserve against" if last_props.empty?
property_id = last_props.first["property_id"]

# The dates are COMPUTED. `availability` refuses a past `check_in` before it
# looks anything up, so a literal would turn this leg into a 400 on the day it
# went stale and the failure would name the wrong thing.
CHECK_IN  = (Date.today + 30).iso8601
CHECK_OUT = (Date.today + 33).iso8601

# `availability` is a QUERY, and by now this agent is well past the free
# allowance — so it is tolled on the read curve and pays its way through.
avail_url = "#{SERVER}/kiosk/availability?" +
            URI.encode_www_form(property_id: property_id, check_in: CHECK_IN, check_out: CHECK_OUT)
rc_avail, avail_resp, avail_proofs = with_pow("availability") { |h| get_json(avail_url, auth.merge(h)) }
abort "availability not served (#{rc_avail}): #{JSON.generate(avail_resp)}" unless rc_avail == 200
avail_rows = Array(avail_resp)
abort "availability returned no room types" if avail_rows.empty?
room_type_id = avail_rows.first.fetch("room_type_id")
$stderr.puts "  [write] availability: #{avail_rows.size} room type(s), #{avail_proofs} proof(s)"

# ── The action itself, in TWO explicit halves so the 402 is the assertion ───
RESERVE_URL  = "#{SERVER}/kiosk/reserve_room"
RESERVE_BODY = { property_id: property_id, room_type_id: room_type_id,
                 check_in: CHECK_IN, check_out: CHECK_OUT }.freeze

rc_write_first, write_first_resp = post_json(RESERVE_URL, RESERVE_BODY, auth)
write_challenges = rc_write_first == 402 ? Array(write_first_resp["challenges"]) : []
$stderr.puts "  [write] reserve_room, no proof: HTTP #{rc_write_first}, " \
             "#{write_challenges.size} challenge(s)"

rc_write = rc_write_first
write_resp = write_first_resp
if write_challenges.any?
  write_proofs = write_challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
  rc_write, write_resp = post_json(
    RESERVE_URL, RESERVE_BODY,
    auth.merge("Kiosk-PoW" => JSON.generate(write_proofs)),
  )
  $stderr.puts "  [write] reserve_room, #{write_proofs.size} proof(s): HTTP #{rc_write}"
end

# Assertions: the first browses are free (0 proofs), and the demanded count is
# non-decreasing and eventually positive — depth got priced.
free_prefix   = curve.take_while { |n| n.zero? }.length
became_priced = curve.any?(&:positive?)
monotonic     = curve.each_cons(2).all? { |a, b| b >= a }

puts JSON.generate(
  browses:       BROWSES,
  curve:         curve,
  free_prefix:   free_prefix,
  became_priced: became_priced,
  monotonic:     monotonic,
  # The write branch. `write_first_status` is the whole assertion — a
  # 402 means an action reached the policy as `:run`; a 200 means the branch
  # never fired at all.
  http_availability:     rc_avail,
  availability_proofs:   avail_proofs,
  write_first_status:    rc_write_first,
  write_challenge_count: write_challenges.size,
  write_status:          rc_write,
  write_booking_id:      (write_resp["booking_id"] if write_resp.is_a?(Hash)),
)
