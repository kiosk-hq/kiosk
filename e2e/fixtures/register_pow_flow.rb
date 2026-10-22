# frozen_string_literal: true

# Register-PoW proof driver — the agent golden-path registration leg WITH a
# real register-time Equihash proof-of-work (the DoD-2 gap: e2e must exercise
# the registration toll, not a toll-free shortcut).
#
# Proves, in one run against the live server:
#   1. A no-proof register is REJECTED with 402 pow_required + challenges[].
#   2. Solving every challenge (bundled numpy solver) and sending the same
#      registration again with the Kiosk-PoW header carrying the solved
#      `{challenge, nonce}` proofs as raw JSON SUCCEEDS (201); the token
#      endpoint then issues a usable token for the new client.
#   3. That token authenticates a real verb.
#   4. The same key on the deployment's second origin is a second account,
#      and each origin refuses the other's token.
#
# Same mechanism the demos use (kiosk-demo-skooti). Emits ONE JSON line on
# stdout for assistant.sh to assert on; non-zero exit on any HTTP failure.
#
# Usage (invoked by assistant.sh — needs a running server + numpy on PATH):
#   SERVER_URL=… KIOSK_ISSUER=… KIOSK_ADDITIONAL_ORIGINS=… bundle exec ruby register_pow_flow.rb
require 'jwt'
require 'json'
require 'net/http'
require 'kiosk/test_helpers/dpop'
require 'kiosk/test_helpers/wire'
require 'uri'
require 'openssl'

SERVER = ENV.fetch('SERVER_URL')
ISSUER = ENV.fetch('KIOSK_ISSUER')

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { 'Content-Type' => 'application/json' }.merge(headers))
  req.body = JSON.generate(body)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

require_relative 'equihash_register'

results = {}

# ── 1. No-proof register is toll-gated (402 pow_required + challenges[]) ──────
rc_noproof, reg_noproof = post_json("#{SERVER}/kiosk/oauth/register", registration_body(OpenSSL::PKey.generate_key('ED25519')))
results[:no_proof_status] = rc_noproof
# RFC 9457: the branch point is the TOP-LEVEL `code`, and `challenges` is a
# top-level extension member beside it.
results[:no_proof_code]   = reg_noproof['code']
results[:challenges_len]  = Array(reg_noproof['challenges']).length
# HOW BIG THE TOLL IS, OFF THE PROTOCOL. `challenges_len` above says how MANY
# proofs this origin demanded; how HARD each one is would otherwise be stated
# only by a comment, which cannot notice a retune. The Equihash (n,k)
# the server PUBLISHES in the challenge it just issued is recorded here, joined
# so one `jq -r` reads the pair as one value: a retune that moved only `n` must
# not slip past an assertion that happened to look at `k`. assistant.sh compares
# it against the pair the fixture initializer CONFIGURED, read out of that file
# rather than typed — a typed expectation would put a fourth hand-kept copy of
# the constant inside the assertion that is supposed to end them.
challenge_params = Array(reg_noproof['challenges']).first&.fetch('params', nil) || {}
results[:challenge_params_nk] = [challenge_params['n'], challenge_params['k']].join(':')

# ── 2. Solve the toll + register succeeds (fresh key via the shared helper) ──
# THE BYTES, KEPT — the same discipline `pay_flow.rb` uses for the
# mandate chain. `POW_CAPTURE` names a file to write the `Kiosk-PoW` header
# value this origin ACCEPTED, so `e2e/schema_conformance.rb` can validate a
# real solved proof against the published `pow.schema.json`. Until this
# existed, `#/$defs/proof` — where `indices`, its Zcash canonical order and the
# inclusive u64 `maximum` live — had no coverage over HTTP at all.
reg_key, reg, token = register_with_token(
  server: SERVER,
  issuer: ISSUER,
  on_proofs: lambda { |proofs|
    capture = ENV.fetch('POW_CAPTURE', nil)
    File.write(capture, JSON.generate(proofs: proofs)) if capture && !capture.empty?
  }
)
results[:with_proof_registered] = !reg.fetch('client_id').to_s.empty? && !token.to_s.empty?
# The pinned registration_role rides inside the token's claims (the 201 body is
# the client information, which names no role). Decode it to prove the agent
# got the server-pinned :customer role it never chose.
claims = JWT.decode(token, nil, false).first
results[:role] = claims['role']

# ── 3. The PoW-minted token authenticates a real verb ──────────────────
# A call that carries a token carries a proof that its key signs for the
# URL of the origin it reaches (RFC 9449).
def dpop(token, key, url) = Kiosk::TestHelpers::Dpop.headers(token, key, method: 'GET', url: url)

rc_wire, wire = get_json("#{SERVER}/kiosk/salons", dpop(token, reg_key, "#{SERVER}/kiosk/salons"))
results[:wire_status] = rc_wire
# A query is answered with the handler's payload verbatim, so
# the proof that the protocol served this token is that a LIST came back — there
# is no `ok` flag left to read, and the status line carries success.
results[:wire_payload_is_array] = wire.is_a?(Array)

# ── 4. A second origin of the same deployment is its own operator ───────────
# The request reaches the same server under the second origin's Host, so the
# deployment resolves it to that origin. The key registered above is unknown
# there: it registers again as a second account, and neither origin's token is
# accepted on the other.
SECOND = ENV.fetch('KIOSK_ADDITIONAL_ORIGINS').split(',').first
second_host = { 'Host' => URI(SECOND).authority }
results[:first_origin_issuer]  = get_json("#{SERVER}/.well-known/kiosk.json").last.dig('kiosk', 'issuer')
results[:second_origin_issuer] = get_json("#{SERVER}/.well-known/kiosk.json", second_host).last.dig('kiosk', 'issuer')
_, second_reg = equihash_register(server: SERVER, key: reg_key, headers: second_host)
results[:second_origin_new_account] = second_reg.fetch('client_id') != reg.fetch('client_id')
rc, second_tok = client_token(server: SERVER, issuer: SECOND, client_id: second_reg.fetch('client_id'), key: reg_key,
                              headers: second_host)
abort "second-origin token request failed (#{rc}): #{JSON.generate(second_tok)}" unless rc == 200
second_token = second_tok.fetch('access_token')
second_salons = "#{SECOND}/kiosk/salons"
results[:second_token_on_second] = get_json("#{SERVER}/kiosk/salons", second_host.merge(dpop(second_token, reg_key, second_salons))).first
results[:first_token_on_second]  = get_json("#{SERVER}/kiosk/salons", second_host.merge(dpop(token, reg_key, second_salons))).first
results[:second_token_on_first]  = get_json("#{SERVER}/kiosk/salons", dpop(second_token, reg_key, "#{SERVER}/kiosk/salons")).first

puts JSON.generate(results)
