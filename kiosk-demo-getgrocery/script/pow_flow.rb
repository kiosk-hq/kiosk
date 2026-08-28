# frozen_string_literal: true

# Getgrocery catalog-toll PoW driver (equihash).
#
# A commerce provider can toll anonymous browsing: the `catalog` query returns
# HTTP 402, the agent solves an Equihash challenge and retries. Proves the loop
# end-to-end with the real shipped solver. One JSON line on stdout.
#
# THE 0.4 WIRE. `catalog` is a QUERY, so it is `GET /kiosk/catalog` with no
# arguments — the toll's request fingerprint is now SHA256("GET catalog\n{}"),
# which is why every call below dials the SAME url with the SAME (empty) query
# string: the challenge binds to the exact request. The proof still rides in the
# `Kiosk-PoW` request HEADER (ADR-0022), which is what lets a GET carry one at
# all. The 402 is an RFC 9457 problem document: `code` and `challenges` are
# TOP-LEVEL members, not nested under an `error` object.
#
# THE PARAMETERS ARE THE SERVER'S, NOT THIS DRIVER'S. Every solve below is
# driven by the challenge the origin issued, so this file works unchanged at
# either level of KIOSK_POW_DIFFICULTY — toy `low` (n=96 k=5, the default) or
# the shipped `high` (n=168 k=7). It reports the served `params` back to
# `rake demo:pow`, which asserts them against the level it asked for, so the
# toll a run pays is a fact off the wire rather than a banner (T-110).
#
# Usage (invoked by rake demo:pow — needs the server with KIOSK_POW_DEMO=1):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/pow_flow.rb
# Requires: python3 with numpy.

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")
# The TOY counter the initializer's on_bad_proof writes (K-590/K-498):
# PER-IDENTITY in sqlite — this driver asserts its own wrong nonce was counted
# against ITS identity and that an innocent second identity stayed at 0.
# The path is OWNED by `rake demo:pow`, which exports it to the server it spawns
# and to this driver (K-711). No default on purpose: this used to be a second
# hand-typed literal, and a drift between the two copies opened an empty sqlite
# here, read 0 for every count, and reported the zeros as a pass. A KeyError is
# the only honest answer when nobody told this process where to look.
BAD_PROOF_DB = ENV.fetch("KIOSK_BAD_PROOF_DB")

# equihash_solve / equihash_register come from the shared helper; the solver
# location is Kiosk::Pow::Equihash.solver_path, owned by the gem (K-627).
require_relative "equihash_register"
require_relative "../app/services/bad_proof_counter"

# EVERY SOLVE THIS FLOW PAYS FOR, COUNTED WHERE THE SOLVER ACTUALLY RUNS (K-1221).
#
# `proofs_solved` used to be `proofs.size` — the challenges THIS file holds, i.e.
# the tolled catalog query's only — and reported 1 for a run that shells out to
# solve.py three times, because `equihash_register` pays the registration toll
# transparently for each identity the flow mints. That is not a cosmetic
# undercount: it is the number a viewer multiplies by the per-proof budget to
# size a recording, and both demos' rake prose had drifted to a hand-typed
# "four" against it.
#
# The counter wraps the helper's `equihash_solve` HERE, in the per-demo driver,
# rather than inside `script/equihash_register.rb` — that file is held in
# lockstep across seven demos by bin/check-demo-copies, and none of the other
# six needs a counter.
POW_SOLVES = { total: 0 }
alias equihash_solve_uncounted equihash_solve
def equihash_solve(challenge)
  POW_SOLVES[:total] += 1
  equihash_solve_uncounted(challenge)
end

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# The tolled call, dialled identically every time so the fingerprint matches.
CATALOG_URL = "#{SERVER}/kiosk/catalog"

# ── Register (register PoW solved transparently) ──────────────────────────────
_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
auth     = { "Authorization" => "Bearer #{reg.fetch("access_token")}" }
agent_id = reg.fetch("agent_id")

# A second, INNOCENT identity (K-498): registers, never submits a bad proof —
# its per-identity count must still be 0 after this flow's wrong nonce.
_key2, reg2 = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
other_agent_id = reg2.fetch("agent_id")

# Everything solved so far was a REGISTRATION toll: this is a snapshot of the
# counter, not a subtraction, so it stays right if the gate's per-identity
# proof count ever moves off `c.registration_pow_count = 1`.
registration_proofs = POW_SOLVES[:total]

# ── Initial catalog query → 402 ─────────────────────────────────────────────
rc_challenge, resp = get_json(CATALOG_URL, auth)
abort "expected 402, got #{rc_challenge}: #{JSON.generate(resp)}" unless rc_challenge == 402
abort "expected pow_required" unless resp["code"] == "pow_required"
challenges = resp["challenges"]
proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }

# ── Wrong nonce → 403 + penalty ─────────────────────────────────────────────
_, neg = get_json(CATALOG_URL, auth)
bad = { "indices" => (1..proofs.first[:nonce]["indices"].length).to_a, "header_nonce" => 0 }
# PoW proof rides in the Kiosk-PoW request header as raw JSON (ADR-0022), never
# in the request — the request stays byte-identical so the challenge fingerprint
# matches, and a GET has no body to put a proof in anyway.
rc_wrong, _ = get_json(CATALOG_URL,
  auth.merge("Kiosk-PoW" => JSON.generate([{ challenge: neg["challenges"].first, nonce: bad }])))
abort "expected 403 for wrong nonce, got #{rc_wrong}" unless rc_wrong == 403
# PER-IDENTITY (K-498): the offender's count moved, the innocent one's did not.
# BOTH halves are asserted here, not just the innocent one (K-707/K-711): the
# innocent check passes trivially against an EMPTY store, so on its own it
# cannot tell "the counter is per-identity" from "this driver is reading a file
# the server never wrote".
bad_proof_count       = BadProofCounter.count(BAD_PROOF_DB, agent_id)
other_bad_proof_count = BadProofCounter.count(BAD_PROOF_DB, other_agent_id)
unless bad_proof_count >= 1
  abort "expected bad_proof_count >= 1 for the offending identity after a wrong nonce, got #{bad_proof_count} — " \
        "the server did not count it, or this driver is reading a different store (#{BAD_PROOF_DB})"
end
unless other_bad_proof_count.zero?
  abort "expected bad_proof_count == 0 for the innocent identity, got #{other_bad_proof_count} — the counter is not per-identity (K-498)"
end

# ── Correct proof → 200 served ──────────────────────────────────────────────
rc_served, served_resp = get_json(CATALOG_URL, auth.merge("Kiosk-PoW" => JSON.generate(proofs)))
# A non-paginating query answers a BARE ARRAY — the whole in-stock shelf. Read it
# as one only when the call actually succeeded, so a refusal (a problem document,
# i.e. a Hash) reaches the abort below verbatim rather than as coerced pairs.
rows = served_resp.is_a?(Array) ? served_resp : []
# DERIVED from the live response, never asserted as a constant (K-707): the
# rake task checks this field, and a field the driver hardcodes makes that
# check decorative. atablefor's pow_flow.rb is the shipped counter-example
# this copies.
served = rc_served == 200 && rows.any?
abort "expected 200 + rows, got #{rc_served}: #{JSON.generate(served_resp)}" unless served

puts JSON.generate(
  http_challenge:             rc_challenge,
  http_served_after_solve:    rc_served,
  http_wrong_nonce:           rc_wrong,
  served:                     served,
  # EVERY solve the flow performed, register included (K-1221) — the count the
  # rake task prints and asserts, and the one a recording's runtime follows from.
  # The tolled catalog query's own share is broken out beside it.
  proofs_solved:              POW_SOLVES[:total],
  registration_proofs_solved: registration_proofs,
  tolled_query_proofs:        proofs.size,
  bad_proof_count:            bad_proof_count,
  other_bad_proof_count:      other_bad_proof_count,
  catalog_rows:               rows.size,
  # THE PARAMETERS THE WIRE ACTUALLY SERVED (T-110), so `rake demo:pow`'s
  # verdict can assert which toll was paid instead of printing what it hoped
  # for. Read off the challenge rather than from config: it follows an operator
  # override or a per-identity policy that a config read cannot see.
  challenge_params:           challenges.first["params"],
)
