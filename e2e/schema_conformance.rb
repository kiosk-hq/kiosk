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
# and the settlement it answered — and validates each against the PUBLISHED
# schema for it, under draft 2020-12.
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
      schema = JSONSchemer.schema(descriptor["input_schema"],
                                  meta_schema: "https://json-schema.org/draft/2020-12/schema")
      errors = schema.validate(descriptor["example_params"]).to_a
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

# ── 6. kyc.schema.json — vendored, compiled, and honestly not exercised ──────
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

puts "\n  pass: #{PASS.size}\n  fail: #{FAIL.size}"
exit 1 unless FAIL.empty?
