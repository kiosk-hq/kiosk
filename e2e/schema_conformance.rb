# frozen_string_literal: true

# THE PUBLISHED JSON SCHEMAS, RUN AGAINST THIS ORIGIN'S LIVE WIRE BYTES (K-822).
#
# WHY THIS FILE EXISTS. `kiosk.tech/spec/schemas/validate.sh` is a real merge
# gate — it compiles all six normative schemas and checks fifteen example
# payloads, including a `rejected/` set that must be REFUSED so a schema that
# quietly went vacuous fails. But every one of those payloads is HAND-WRITTEN.
# Nothing joined the schemas to a SERVED byte, so the two artifacts could drift
# apart indefinitely with both suites green: the schemas checked against a
# fiction, the code checked against its own specs, and the pair never met. That
# is the K-811 failure — an oracle whose subject has moved — one layer down,
# and §16.3 anchor 1 ("every wire object validates against its JSON Schema") is
# the requirement it leaves untested.
#
# WHAT IT DOES. It is handed the bytes the e2e assistant has already made this
# origin produce — the discovery document, the catalog, four problem documents
# across four codes (one of them carrying live PoW challenges), the pay request
# and the settlement it answered, and every wire object of Sections 5 and 6
# (T-152) — and validates each against the PUBLISHED schema for it, under draft
# 2020-12.
#
# THE SCHEMAS ARE VENDORED, and that was a fork in the road: they live in the
# kiosk.tech repo and this harness lives here, so joining them needs either a
# copy or a fetch. A copy, for the same reason kiosk-server already vendors
# `pow.schema.json` — a network fetch makes a merge gate depend on a live site,
# which is the one thing a gate must not do — and the copy's honesty is a
# separate check, `bin/check-spec-schemas`, which compares it against the real
# thing whenever the umbrella layout puts kiosk.tech next to this repo and says
# so rather than pretending when it does not. `pow.schema.json` is NOT copied a
# second time: this file reads the one kiosk-server already ships.
#
# NON-VACUITY IS PART OF THE CHECK, not an assumption. Every validation here is
# paired with a MUTATED copy of the same live bytes that the schema MUST
# refuse — `validate.sh`'s `chkfail` discipline applied to served data. Without
# that, a schema whose `enum` or `required` had gone soft would validate
# everything and this file would print PASS while checking nothing, which is
# precisely the failure it was written to close.
#
# Usage (invoked by e2e/run.sh from the generated app dir, so json_schemer —
# a kiosk-server RUNTIME dependency since 0.4 — is on the load path):
#
#   SERVER_URL=http://127.0.0.1:3001 KIOSK_ISSUER=… TOKEN=… \
#     bundle exec ruby <repo>/e2e/schema_conformance.rb
#
# Exits non-zero on any failure.

require "json"
require "json_schemer"
require "net/http"
require "uri"
# The RESERVED wire names, read from the engine rather than restated (§4). Its
# own requires are `date`, `time`, `rack` and `kiosk/server/errors` — all
# loadable without Rails, which is what lets this bare `ruby` process have them.
require "kiosk/server/argument_decoder"

SERVER  = ENV.fetch("SERVER_URL")
E2E_DIR = __dir__
SCHEMA_DIR = File.join(E2E_DIR, "schemas")
# The sixth schema is not copied here — kiosk-server vendors it already, for
# its own request-shape validation, and one repo holding two copies of one file
# is the drift this whole exercise is about.
POW_SCHEMA = File.expand_path(
  "../kiosk-server/lib/kiosk/server/schemas/pow.schema.json", E2E_DIR
)

PASS = []
FAIL = []

def ok(label)
  PASS << label
  puts "  \e[1;32m✓\e[0m #{label}"
end

def bad(label, detail)
  FAIL << label
  puts "  \e[1;31m✗\e[0m #{label}\n     #{detail}"
end

# ── the schema set ───────────────────────────────────────────────────────────
#
# Loaded from disk and registered under their own `$id`s, so `problem`'s
# cross-file `$ref` to `pow.schema.json#/$defs/challenge` resolves LOCALLY —
# a validator that reached out to https://kiosk.tech to resolve it would be
# testing the network, and would pass on a stale cache.
DOCS = {}
Dir[File.join(SCHEMA_DIR, "*.schema.json")].sort.each do |path|
  doc = JSON.parse(File.read(path))
  DOCS[doc.fetch("$id")] = doc
end
pow_doc = JSON.parse(File.read(POW_SCHEMA))
DOCS[pow_doc.fetch("$id")] = pow_doc

REF_RESOLVER = lambda do |uri|
  DOCS[uri.to_s.split("#").first] or
    raise "schema_conformance: unresolvable $ref #{uri} — a schema references a " \
          "document this harness does not vendor"
end

# @param id [String] the `$id` of the schema document
# @param pointer [String, nil] a JSON pointer to a `$defs` member, when the
#   subject is one part of a multi-definition document (the mandates file)
def schema_for(id, pointer = nil)
  root = DOCS.fetch(id)
  root = root.merge("$ref" => pointer) if pointer
  JSONSchemer.schema(root, meta_schema: "https://json-schema.org/draft/2020-12/schema",
                           ref_resolver: REF_RESOLVER)
end

# THE PAIRED ASSERTION. `payload` must validate; `mutate` must produce
# something the SAME schema refuses. The second half is not decoration: it is
# what distinguishes "the wire conforms" from "this schema accepts anything".
#
# @param label   [String] what is being checked, for the log
# @param id      [String] schema `$id`
# @param payload [Object] the LIVE bytes, already parsed
# @param pointer [String, nil] `$defs` pointer, when the document defines many
# @param mutate  [Proc] given a deep copy of the payload, breaks it
def conforms(label, id, payload, pointer: nil, &mutate)
  schema = schema_for(id, pointer)
  errors = schema.validate(payload).to_a
  if errors.empty?
    ok "#{label} validates against #{File.basename(id)}#{pointer ? " #{pointer}" : ""}"
  else
    bad "#{label} does NOT validate against #{File.basename(id)}",
        errors.first(3).map { |e| e["error"] }.join("; ")
  end

  raise ArgumentError, "#{label}: no control mutation given" unless mutate

  broken = mutate.call(JSON.parse(JSON.generate(payload)))
  if schema.valid?(broken)
    bad "#{label}: the schema ACCEPTED a deliberately broken copy",
        "the check above proves nothing — #{File.basename(id)} is vacuous for this payload"
  else
    ok "…and the same schema REFUSES a broken copy of those very bytes"
  end
end

def get(path, headers = {})
  uri = URI("#{SERVER}#{path}")
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, res.body]
end

def post(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = body
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, res.body]
end

def parse(raw) = JSON.parse(raw)

B = "https://kiosk.tech/spec/schemas"

puts "\n\e[1m=== published JSON Schemas vs this origin's LIVE bytes (§16.3 anchor 1) ===\e[0m"

# ── 1. the discovery document ────────────────────────────────────────────────
_status, raw = get("/.well-known/kiosk.json")
conforms("GET /.well-known/kiosk.json", "#{B}/discovery.schema.json", parse(raw)) do |doc|
  doc["kiosk"]["auth"]["kind"] = "oauth2"  # `kind` is a const
  doc
end

# ── 2. the catalog ───────────────────────────────────────────────────────────
_status, raw = get("/kiosk/schema")
catalog = parse(raw)
conforms("GET /kiosk/schema", "#{B}/schema-descriptor.schema.json", catalog) do |doc|
  # T-095 deleted `verbs`, and the schema's root is CLOSED so it can say so.
  doc["verbs"] = ["schema", "queries"]
  doc
end

# ── 3. problem documents, one per shape the origin can produce ───────────────
#
# FOUR codes and four different code paths: the auth plane's 402 (with LIVE PoW
# challenges, which is the only thing that exercises problem.schema.json's
# cross-file `$ref` into pow.schema.json), the identity gate's 401, the
# registry's 404 and the router's 405. One of them would have proved the media type
# and the flat `code`; four prove the vocabulary is not a single hard-coded
# path.
problems = []

# A REAL public key, because the toll is not the first gate a garbage one
# trips: `registration_pow_count` is paid before the possession proof is
# verified, but a key that will not parse is refused earlier still, and the
# 402 this block is here to capture would never be issued.
require "openssl"
status, raw = post("/kiosk/auth/register",
                   JSON.generate(public_key: OpenSSL::PKey::RSA.new(2048).public_key.to_pem,
                                 signed: "not-reached-the-toll-comes-first"))
problems << ["POST /kiosk/auth/register (unpaid toll, #{status})", parse(raw)]

status, raw = get("/kiosk/salons")
problems << ["GET /kiosk/salons unauthenticated (#{status})", parse(raw)]

TOKEN = ENV.fetch("TOKEN")
AUTH  = { "Authorization" => "Bearer #{TOKEN}" }

status, raw = get("/kiosk/no_such_verb", AUTH)
problems << ["GET /kiosk/no_such_verb (#{status})", parse(raw)]

status, raw = post("/kiosk/salons", "{}", AUTH)
problems << ["POST /kiosk/salons — a query is not a POST (#{status})", parse(raw)]

problems.each do |label, doc|
  conforms(label, "#{B}/problem.schema.json", doc) do |broken|
    # `code` is the closed vocabulary — the one member an assistant branches
    # on, and the one this schema exists to keep closed.
    broken["code"] = "teapot"
    broken
  end
end

# The 402 is the one that carries `challenges`, and therefore the one that
# reaches pow.schema.json through problem.schema.json's cross-file `$ref`.
# Asserted explicitly, because a 402 that stopped carrying them would still
# validate — `challenges` is optional — and the cross-file reference would then
# be checked by nothing at all.
pow_problem = problems.first.last
if pow_problem["code"] == "pow_required" && pow_problem["challenges"].is_a?(Array) &&
   !pow_problem["challenges"].empty?
  ok "the 402 carries live PoW challenges, so the cross-file $ref into pow.schema.json is exercised"
  conforms("one live PoW challenge", "#{B}/pow.schema.json",
           pow_problem["challenges"].first, pointer: "#/$defs/challenge") do |ch|
    ch.delete("sig")  # `sig` is required — without it a challenge is unbindable
    ch
  end
else
  bad "the 402 carries live PoW challenges",
      "got code=#{pow_problem["code"].inspect} challenges=#{pow_problem["challenges"].inspect} — " \
      "without them problem.schema.json's $ref into pow.schema.json is never followed"
end

# ── 4. §8.3 — a descriptor's EXAMPLES against that descriptor's OWN schemas ──
#
# Matrix SPEC-084. The catalog publishes `example_params` and `example_row` so
# an assistant can copy one verbatim as a starting call; the spec says the
# example ILLUSTRATES the contract and the SCHEMA is the contract where they
# disagree. Nothing checked that they agree at all, so a verb could ship an
# example its own `input_schema` rejects — and the assistant that copied it
# would get a 400 from the origin that published it.
#
# The bytes here are the SERVED catalog, so this validates what an assistant
# actually reads, not what a controller file says.
examples_checked = 0
%w[queries actions].each do |kind|
  Array(catalog[kind]).each do |descriptor|
    name = descriptor["name"]

    if descriptor.key?("example_params")
      # `limit` and `cursor` are RESERVED (§8.1 item 6, §8.4): the wire always
      # accepts them and a verb never declares them, so an `input_schema` with
      # `additionalProperties: false` still takes one and an `example_params`
      # may legitimately show one. {RequestValidation#validate_arguments!}
      # drops exactly this set — minus any the verb declares for itself, which
      # is the more specific statement — before validating a real request, so a
      # check that did not would refuse an example the origin ACCEPTS. Read
      # from the engine's own constant; a second copy is the drift this file
      # exists to catch elsewhere. (K-1273, found extending §4 to the demos.)
      declared_props = Kiosk::Server::ArgumentDecoder.fetch(descriptor["input_schema"], :properties)
      exempt = Kiosk::Server::ArgumentDecoder::RESERVED.keys -
               (declared_props.is_a?(Hash) ? declared_props.keys.map(&:to_s) : [])
      payload = descriptor["example_params"]
      payload = payload.reject { |key, _| exempt.include?(key) } if payload.is_a?(Hash)

      schema = JSONSchemer.schema(descriptor["input_schema"],
                                  meta_schema: "https://json-schema.org/draft/2020-12/schema")
      errors = schema.validate(payload).to_a
      examples_checked += 1
      if errors.empty?
        ok "#{name}: example_params satisfies its own input_schema"
      else
        bad "#{name}: example_params VIOLATES its own input_schema",
            errors.first(3).map { |e| e["error"] }.join("; ")
      end
    end

    next unless descriptor.key?("example_row")

    # `example_row` is ONE ELEMENT of the answer, so for a query — whose
    # output_schema is an array schema (§8.2) — it is checked against `items`,
    # not against the array. An action's answer is the object itself.
    out = descriptor["output_schema"]
    row_schema = if out.is_a?(Hash) && out["type"] == "array" && out["items"]
                   # `$defs` stay in scope: `items` is routinely a `$ref` into them.
                   out.reject { |k, _| %w[type description items].include?(k) }
                      .merge(out["items"].is_a?(Hash) ? out["items"] : {})
                 else
                   out
                 end
    next if row_schema == true || row_schema.nil?

    schema = JSONSchemer.schema(row_schema,
                                meta_schema: "https://json-schema.org/draft/2020-12/schema")
    errors = schema.validate(descriptor["example_row"]).to_a
    examples_checked += 1
    if errors.empty?
      ok "#{name}: example_row satisfies its own output_schema"
    else
      bad "#{name}: example_row VIOLATES its own output_schema",
          errors.first(3).map { |e| e["error"] }.join("; ")
    end
  end
end

# The control for the loop itself. A `for` over an empty list passes silently,
# and this origin's fixtures declare four examples; a refactor that stopped
# publishing them would turn the whole block above into a no-op that prints
# nothing and fails nothing.
if examples_checked >= 4
  ok "…across #{examples_checked} published examples (the loop is not empty)"
else
  bad "descriptor examples were checked", "only #{examples_checked} examples found in the served " \
      "catalog — the §8.3 loop above asserted almost nothing"
end

# ── 5. the AP2 mandate chain and the settlement it answered ──────────────────
#
# Read from the file e2e/run.sh had pay_flow.rb write: these are the REQUEST
# this origin accepted and the RESPONSE it produced, not a reconstruction.
pay_capture = ENV["PAY_CAPTURE"]
if pay_capture && File.exist?(pay_capture)
  cap = JSON.parse(File.read(pay_capture))

  conforms("the pay REQUEST body", "#{B}/mandates.schema.json", cap.fetch("request"),
           pointer: "#/$defs/payRequest") do |body|
    body.delete("cart_mandate_jws")  # all three are required — the chain is the point
    body
  end

  %w[intent cart payment].each do |defn|
    conforms("the #{defn} mandate's claims", "#{B}/mandates.schema.json",
             cap.fetch("claims").fetch(defn), pointer: "#/$defs/#{defn}") do |claims|
      # `exp` is REQUIRED on every mandate by `baseClaims` — "a missing or
      # passed exp is rejected" — and it reaches this `$def` through an
      # `allOf`, so the control also proves the composition is being applied.
      claims.delete("exp")
      claims
    end
  end

  conforms("the settlement this origin answered", "#{B}/mandates.schema.json",
           cap.fetch("response"), pointer: "#/$defs/settlement") do |settled|
    settled["settled_amount_cents"] = "1599"  # integer cents, never a string
    settled
  end
else
  bad "the AP2 mandate chain was validated",
      "PAY_CAPTURE (#{pay_capture.inspect}) is missing — pay_flow.rb did not write the " \
      "captured request/claims/response, so five mandate schemas checked nothing"
end

# ── 6. the SOLVED PoW proof, against `pow.schema.json#/$defs/proof` (K-849) ──
#
# `pow.schema.json` has two halves and only one of them was ever reached from
# here. The 402 above follows `problem.schema.json`'s cross-file `$ref` into
# `#/$defs/challenge` — the half the SERVER writes. `#/$defs/proof` is the half
# the CLIENT writes, and it is where `indices`, its Zcash canonical order and
# the INCLUSIVE u64 `maximum` (K-839, K-845) live. Those rows were gated by a
# run that structurally could not have failed on them: their only executable
# coverage was a kiosk-server unit spec and kiosk.tech's hand-written examples,
# neither of which sees live bytes.
#
# No new solve is needed — the harness already solves a real register toll, and
# `register_pow_flow.rb` writes the header value the origin ACCEPTED to
# POW_CAPTURE. The whole array is validated against the ROOT schema too, which
# is `$ref`d to `#/$defs/powHeader`: that is the one thing asserting the
# ARRAY-of-proofs presentation of ADR-0022's raw-JSON header.
pow_capture = ENV["POW_CAPTURE"]
if pow_capture && !pow_capture.empty? && File.exist?(pow_capture)
  proofs = JSON.parse(File.read(pow_capture)).fetch("proofs")

  if proofs.is_a?(Array) && !proofs.empty?
    ok "the register toll fired and its solved proof(s) were kept (#{proofs.length})"

    conforms("the Kiosk-PoW header this origin ACCEPTED", "#{B}/pow.schema.json", proofs) do |hdr|
      # ONE PAST THE INCLUSIVE u64 BOUND. This is the bound K-845 argued about
      # and the reason the control is here: a schema that stated the bound
      # exclusively, or dropped it, would accept this and the check above would
      # be proving nothing about the range at all.
      hdr.first["nonce"]["indices"][0] = 18_446_744_073_709_551_616
      hdr
    end

    conforms("one solved PoW proof", "#{B}/pow.schema.json", proofs.first,
             pointer: "#/$defs/proof") do |proof|
      # `challenge` is REQUIRED beside `nonce`: a proof that did not echo the
      # challenge back verbatim is unbindable to the request it paid for.
      proof.delete("challenge")
      proof
    end
  else
    bad "the register toll fired and its solved proof(s) were kept",
        "POW_CAPTURE holds #{proofs.inspect} — no proof to validate, so pow.schema.json's " \
        "`#/$defs/proof` half is again reached by nothing"
  end
else
  bad "the solved PoW proof was validated",
      "POW_CAPTURE (#{pow_capture.inspect}) is missing — register_pow_flow.rb did not write the " \
      "accepted Kiosk-PoW header, so `#/$defs/proof` and the u64 index bound checked nothing"
end

# ── 7. kyc.schema.json — vendored, compiled, and honestly not exercised ──────
#
# This origin serves no KYC: the attestation flow is a TWO-SERVER integration
# and lives in the skooti/getgrocery demos against kiosk-demo-prove. The schema
# is vendored anyway so `bin/check-spec-schemas` mirrors the published set
# COMPLETELY — a partial mirror is the trap where the one file nobody copied is
# the one that drifts. What can be checked here is that it still COMPILES, which
# is what validate.sh checks for every schema before it validates anything.
begin
  schema_for("#{B}/kyc.schema.json")
  ok "kyc.schema.json compiles (no live KYC bytes on this origin — see the demos)"
rescue StandardError => e
  bad "kyc.schema.json compiles", e.message
end

# ── 8. §5 and §6 — the auth and binding planes (T-152) ──────────────────────
#
# auth.schema.json and binding.schema.json shipped with T-149 and were vendored
# beside the other six the same day, so this file LOADED and COMPILED them from
# the moment they existed — and validated nothing against them. That is K-822's
# own defect one layer on: the pair of artefacts sat in the same process and
# never met. `fixtures/auth_wire_capture.rb` runs both ceremonies against this
# still-booted origin and writes down what went over the wire, request bodies
# included; every one of the THIRTEEN `$defs` those two documents publish is
# validated below against the bytes this origin produced for it, each paired
# with a mutated copy the same schema must refuse.
#
# WHAT IS NOT HERE, and it is not an omission: the two /oauth/* REQUESTS are
# form-encoded rather than JSON, so no JSON Schema is their oracle and none
# exists to run (T-149, K-1248; binding.schema.json's own description and §17
# both say so). The driver still sends them — that is how the answers below
# come to exist — but there is nothing to validate them against. `unlink`'s
# 204 is the other one: §6.3 gives it no body at all, which is asserted here as
# a length rather than as a schema.
auth_capture = ENV["AUTH_CAPTURE"]
if auth_capture && !auth_capture.empty? && File.exist?(auth_capture)
  auth = JSON.parse(File.read(auth_capture))
  A = "#{B}/auth.schema.json"
  BI = "#{B}/binding.schema.json"

  # §5.1 — the challenge this origin issued for a real key.
  conforms("GET /auth/challenge", A, auth.fetch("challenge"),
           pointer: "#/$defs/challenge") do |doc|
    doc.delete("exp")  # required: a challenge with no expiry is not short-lived
    doc
  end

  # §5.2 — the payload of the `signed` JWS this origin ACCEPTED. `aud` is the
  # origin binding, and dropping it is the difference between a proof and a
  # relayable one.
  conforms("the possession proof this origin accepted", A, auth.fetch("possession_proof"),
           pointer: "#/$defs/possessionProof") do |doc|
    doc.delete("aud")
    doc
  end

  # §5.3 — the login body, which is register's body member for member.
  conforms("the POST /auth/login body", A, auth.fetch("credential_request"),
           pointer: "#/$defs/credentialRequest") do |doc|
    doc.delete("signed")  # a public key with no proof is an assertion, not a credential
    doc
  end

  # §5.3 — the tolled 201.
  conforms("the POST /auth/register 201", A, auth.fetch("registration"),
           pointer: "#/$defs/registration") do |doc|
    doc.delete("access_token")
    doc
  end

  # §5.4 — what the operator put INSIDE the token it minted. `actor` is a
  # `const`, and it is the one member that says this is a Kiosk access token
  # rather than some other JWT the same key signed.
  conforms("the access token's claims", A, auth.fetch("access_token_claims"),
           pointer: "#/$defs/accessTokenClaims") do |doc|
    doc["actor"] = "human"
    doc
  end

  # §5.3 and §5.5 — login's answer and revoke's answer are ONE object, and the
  # two arms carry different controls on purpose: `required` on one side,
  # `type` on the other, so neither half of the `$def` is taken on trust.
  conforms("the POST /auth/login 200", A, auth.fetch("token_login"),
           pointer: "#/$defs/token") do |doc|
    doc.delete("access_token")
    doc
  end
  conforms("the POST /auth/revoke 200 — the SAME object (K-1249)", A, auth.fetch("token_revoke"),
           pointer: "#/$defs/token") do |doc|
    doc["access_token"] = 1  # a compact JWT is a string
    doc
  end

  # §6.2 — the human's link code, minted on a real Devise session.
  conforms("the POST /auth/link 201", BI, auth.fetch("link_code"),
           pointer: "#/$defs/linkCode") do |doc|
    doc["expires_in"] = "900"  # seconds, an integer — not the string spelling
    doc
  end

  conforms("the POST /auth/claim body", BI, auth.fetch("claim_request"),
           pointer: "#/$defs/claimRequest") do |doc|
    doc.delete("code")  # without the code this is a bare register
    doc
  end

  # §6.2 — the claim answer, whose `$def` is a CROSS-FILE `$ref` into
  # auth.schema.json's `registration`. The control therefore breaks a member
  # that only the REFERENCED document declares: if the `$ref` were not followed
  # the mutation would pass and this line would be proving nothing.
  conforms("the POST /auth/claim 201", BI, auth.fetch("claim_response"),
           pointer: "#/$defs/claimResponse") do |doc|
    doc.delete("user_id")
    doc
  end

  # §6.1 step 1 — all six members are REQUIRED here, which is narrower than RFC
  # 8628 makes them, so `interval` is the control: an operator porting a stock
  # device-grant answer is exactly who this refusal is for.
  conforms("the POST /oauth/device_authorization 200", BI, auth.fetch("device_authorization"),
           pointer: "#/$defs/deviceAuthorization") do |doc|
    doc.delete("interval")
    doc
  end

  # §6.1 — the two OAuth refusals, the one place on this wire that is not an
  # RFC 9457 problem document. The first is the clause `oauthError` was widened
  # for: §6.1 step 1 requires `invalid_request` for a `role` parameter, and an
  # enum written from the section's own closing list of six could not say it.
  conforms("the /oauth/device_authorization refusal of a `role` parameter", BI,
           auth.fetch("oauth_error_role_refused"), pointer: "#/$defs/oauthError") do |doc|
    doc["error"] = "role_not_allowed"  # the vocabulary is CLOSED at eight
    doc
  end
  conforms("the /oauth/token refusal of an unknown grant_type", BI,
           auth.fetch("oauth_error_unsupported_grant"), pointer: "#/$defs/oauthError") do |doc|
    doc.delete("error")
    doc
  end

  # The `error` VALUES, which no schema can pin to an endpoint: the enum says
  # the vocabulary is closed, not which member each refusal owes.
  if auth.dig("oauth_error_role_refused", "error") == "invalid_request"
    ok "…and the role refusal is `invalid_request`, the code §6.1 step 1 names"
  else
    bad "the role refusal is `invalid_request`",
        "got #{auth.dig("oauth_error_role_refused", "error").inspect}"
  end
  if auth.dig("oauth_error_unsupported_grant", "error") == "unsupported_grant_type"
    ok "…and an unknown grant_type is `unsupported_grant_type`"
  else
    bad "an unknown grant_type is `unsupported_grant_type`",
        "got #{auth.dig("oauth_error_unsupported_grant", "error").inspect}"
  end

  # §6.1 step 3 — the answer to the poll that COMPLETED the ceremony, after a
  # real human approved on the real verify page.
  conforms("the POST /oauth/token 200 (the completed device grant)", BI,
           auth.fetch("device_token_response"), pointer: "#/$defs/deviceTokenResponse") do |doc|
    doc["token_type"] = "bearer"  # `const` "Bearer" — the spelling is the contract
    doc
  end

  # §6.3 — the unlink body. Its RESPONSE has no schema because it has no body,
  # which is asserted right after as the length it must be.
  conforms("the POST /auth/unlink body", BI, auth.fetch("unlink_request"),
           pointer: "#/$defs/unlinkRequest") do |doc|
    doc["agent_id"] = 42
    doc
  end
  if auth["unlink_status"] == 204 && auth["unlink_body_len"].to_i.zero?
    ok "…and /auth/unlink answered 204 with no body at all (§6.3, K-870)"
  else
    bad "/auth/unlink answered 204 with no body at all",
        "status=#{auth["unlink_status"].inspect} body_len=#{auth["unlink_body_len"].inspect}"
  end

  # The `$ref` claim itself, stated as an assertion rather than left to be
  # inferred from two arms that both passed: §6.2 says the claim answer is the
  # register answer «byte-for-byte the same shape», which is why the schema
  # refers rather than restates. Two objects that both validate could still
  # differ — one may carry a member the open root permits.
  if auth.fetch("claim_response").keys.sort == auth.fetch("registration").keys.sort
    ok "…and the claim 201 carries exactly the register 201's members (§6.2's `$ref`, not a coincidence)"
  else
    bad "the claim 201 carries exactly the register 201's members",
        "claim=#{auth.fetch("claim_response").keys.sort.inspect} " \
        "register=#{auth.fetch("registration").keys.sort.inspect}"
  end
else
  bad "the §5/§6 auth and binding wire objects were validated",
      "AUTH_CAPTURE (#{auth_capture.inspect}) is missing — auth_wire_capture.rb did not write " \
      "the ceremonies' bytes, so auth.schema.json and binding.schema.json checked nothing"
end

puts "\n  pass: #{PASS.size}\n  fail: #{FAIL.size}"
exit 1 unless FAIL.empty?
