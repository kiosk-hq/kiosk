# kiosk-reputation

Policy and wire-challenge layer for Kiosk's proof-of-work system.

## Overview

`kiosk-reputation` decides *when* and *how hard* to challenge a request with a
proof-of-work, issues and verifies the signed wire challenge, and provides a
pluggable reputation policy interface.

**Pure Ruby — no dependency on kiosk-pow or kiosk-core.** A PoW backend registers
with `Kiosk::Reputation::Backends.register`. In a Rails app `kiosk-pow-equihash`
registers itself at boot; the host registers any other backend (see
[Installation](#installation)). This gem is backend-agnostic:
the shipped default is **equihash** (`kiosk-pow-equihash`); `kiosk-pow-argon2id`
provides Argon2id (legacy, registers as `argon2id`); `kiosk-pow-cuckoo` provides
Cuckatoo Cycle (opt-in, registers as `cuckatoo`). Each backend is built on
`kiosk-pow`, whose README tells how to add a backend.

## Wire protocol

### Challenge — HTTP 402 `pow_required`

When the provider's reputation policy decides to challenge a request, the server
responds with HTTP 402 instead of serving. The answer is an RFC 9457 problem
document (`application/problem+json`, accompanied by
`WWW-Authenticate: Kiosk-PoW realm="<issuer>"`) whose flat top-level `code` is
`pow_required` and which carries a **`challenges` array** (plural) as an
extension member — the policy demands `count` independent proofs (N×PoW). A
normal request gets one challenge; a suspicious one gets several:

```json
{
  "type":   "https://kiosk.tech/problems/pow_required",
  "title":  "Proof-of-work required",
  "status": 402,
  "detail": "proof-of-work required",
  "code":   "pow_required",
  "challenges": [
    {
      "id":     "<uuid>",
      "alg":    "equihash",
      "params": { "n": 168, "k": 7 },
      "salt":   "<base64 of 16 raw bytes, fresh per challenge>",
      "exp":    1750000600,
      "sig":    "<HMAC-SHA256 hex over canonical(id|alg|params|salt|exp|request_fingerprint)>"
    }
  ]
}
```

Key properties:

- **`challenges` is a list of N independent challenges.** Equihash has no
  continuous difficulty dial (memory is fixed by `(n, k)`) — the anti-abuse
  lever is PROOF COUNT. Each challenge has its own `id` and fresh `salt`, so
  there is no amortisation: all N must be solved to prove work for this request.
- `alg` + `params` are **mandated** — no client negotiation field. `equihash`
  is the shipped default; `argon2id` is legacy.
- `salt` is fresh per challenge — prevents precomputation / rainbow tables.
- `sig` is HMAC-SHA256 (provider `pow_secret`) over the challenge fields **and
  a fingerprint of the original request**
  (`SHA256(METHOD + " " + verb + "\n" + canonical_json(args))` — see the retry
  section below for why that formula matches on retry by construction).
  Each challenge is stateless-verifiable (no server storage needed to trust it)
  and bound to that specific request (a proof cannot be replayed against a
  different call).
- `exp` bounds the replay window; when N > 1 the server scales the TTL with the
  count so a slow client solving proofs sequentially does not race expiry.

### Proof — client re-sends the same request, proof(s) in the `Kiosk-PoW` header

The client solves each challenge and re-sends the SAME request — same method,
same path, same query string, same body — with the proof(s) in a **`Kiosk-PoW`
request header** as raw minified JSON, one `{challenge, nonce}` entry
per solved challenge. The wire makes most calls GETs (a query is
`GET <endpoint>/<query-name>`), and a GET has no body, so the header is the ONLY
channel a proof can travel on:

```http
GET /kiosk/menu_by_restaurant?restaurant=Mamma%20Pizza
Kiosk-PoW: [{"challenge":{ "...echoed verbatim...": true },"nonce":{"indices":[…]}}]
```

A single proof may be sent bare (`Kiosk-PoW: {"challenge":{…},"nonce":{…}}`), as a
JSON array of N proofs, or as repeated `Kiosk-PoW` header lines (one proof each) —
all flatten to one proofs list. Because the proof rides in the header, the
request is byte-identical at issue time (no proof) and verify time (proof in the
header), so the request fingerprint —
`SHA256(METHOD + " " + verb + "\n" + canonical_json(args))` — matches on retry by
construction; there is no `pow` body field to exclude. That formula binds a proof
to the exact call: the method, the verb as it appears in the path, and the
canonical arguments, so a proof solved for `GET /catalog?city=Lisbon` is
spendable on nothing else.

## Anti-DoS invariant: cheap checks before the expensive backend eval

`Challenge.verify` enforces this order — always:

1. Recompute + compare HMAC sig (constant-time `OpenSSL.fixed_length_secure_compare`)
   → `:bad_sig` (tampered, wrong request binding, or forged challenge)
2. Expiry check (`exp > now`) → `:expired`
3. Parameter re-derivation against the caller's live config (`expect:`)
   → `:bad_params` (see below)
4. **Only then**: one backend eval (equihash verify — 2^k BLAKE2b hashes, ~ms + KB)
   → `:ok` / `:bad_proof`

Floods of forged, expired or off-spec proofs are rejected at steps 1/2/3 without
burning a backend eval. This is not optional; it is tested.

## Server-side parameter re-derivation (`expect:`)

The challenge is stateless, so `alg`/`params` travel on the wire and come back
from the client. The HMAC sig proves *we minted them*; it does **not** prove they
are still the difficulty this server demands. Pass `expect:` — the spec the
caller just re-derived from its own configuration for this request — and
`verify` refuses any challenge naming other parameters, however valid its sig:

```ruby
Kiosk::Reputation::Challenge.verify(
  challenge: challenge, nonce: solution,
  request_fingerprint: fp, secret: secret, now: Time.now.to_i,
  expect: { alg: "equihash", params: { n: 168, k: 7 } }   # from YOUR config, not the wire
)
```

Two things this buys: a challenge minted just before a difficulty raise stops
being solvable at the old cheap parameters for the rest of its TTL, and a leaked
HMAC secret cannot let a self-signed `{n: 8, k: 1}` challenge turn the toll
off — the toll degrades rather than vanishing. `kiosk-server`'s gate always
passes `expect:`; it is optional here so an existing embedder keeps working.

Comparison uses the same canonical `k=v` rendering the sig covers, so key order,
Symbol-vs-String keys and `168` vs `"168"` are all equal — it rejects a different
difficulty and nothing else. `:bad_params` means **re-challenge, not bad faith**:
`kiosk-server` releases the challenge id and answers 402 at current params
(never 403, never `on_bad_proof`).

## Components

### `Backends`

Registry mapping algorithm names to PoW backend objects.

```ruby
Kiosk::Reputation::Backends.register("equihash", Kiosk::Pow::Equihash)
Kiosk::Reputation::Backends.fetch("equihash")   # => Kiosk::Pow::Equihash
Kiosk::Reputation::Backends.known               # => ["equihash"]
```

A registered backend need only respond to:
- `.verify(salt:, params:, nonce:) → Boolean` — verify a submitted proof
  (`Challenge.verify` resolves the backend via `fetch` and calls only this).

Backends also expose a `.params` helper for building challenge params, but its
signature is algorithm-specific (equihash `(n:, k:)`, argon2id `(d:, m:, t:, p:)`,
cuckatoo `(edgebits:, proofsize:, target:)`) and it is called directly on the
concrete backend by the host, never through this registry.

### `Challenge`

Stateless, request-bound wire challenge. The caller (`kiosk-server`) maintains a
spent-id set (TTL ≤ `challenge[:exp]`) to prevent replay of a valid proof —
`Challenge` itself does not track spent ids.

```ruby
challenge = Kiosk::Reputation::Challenge.issue(
  alg:                  "equihash",
  params:               { n: 168, k: 7 },
  request_fingerprint:  "sha256:...",
  secret:               "provider-hmac-key",
  ttl:                  300            # seconds; exp = Time.now.to_i + ttl
)
# => { id:, alg:, params:, salt: <base64>, exp:, sig: }

result = Kiosk::Reputation::Challenge.verify(
  challenge:            challenge,
  nonce:                client_solution,   # opaque to Challenge; passed to the backend .verify
  request_fingerprint:  "sha256:...",
  secret:               "provider-hmac-key",
  now:                  Time.now.to_i,
  expect:               { alg: "equihash", params: { n: 168, k: 7 } }  # optional; from live config
)
# => :ok | :bad_sig | :expired | :bad_params | :bad_proof
```

### `Factors`

Immutable bundle of reputation inputs the host populates per request. All
fields are nullable — the provider decides which ones to track.

```ruby
factors = Kiosk::Reputation::Factors.new(
  kyc_level:               nil,          # nil | :basic | :verified
  settled_purchases_count: 0,            # number of completed purchases
  settled_purchases_cents: nil,          # total purchase value in cents
  request_rate_per_min:    120,          # recent request rate (req/min)
  account_age_seconds:     nil,          # seconds since account creation
  dispute_count:           nil,          # disputes filed
  bad_proof_count:         2             # invalid PoW proofs submitted (bad-faith signal)
)

Kiosk::Reputation::Factors.empty         # all-nil convenience constructor
```

The `request_rate_per_min` field is supplied by the host (which owns its own
rate accounting); `kiosk-reputation` does not mandate a rate store, only
consumes the number. The `bad_proof_count` field is a clear bad-faith signal —
an honest client solver never submits a wrong proof.

### `Policy` (base)

```ruby
class MyPolicy < Kiosk::Reputation::Policy
  # @param identity [Object]  opaque identity value from the host
  # @param verb     [Symbol]  the WIRE command — :query, :run or :pay. Not the
  #   declaration name: a verb a handler declares as `kind :action` in
  #   kiosk-server arrives here as :run (VerbController#create serves
  #   `serve(:run)`), so branch on :run rather than on :action. The protocol
  #   states the same mapping in its Reputation section, and kiosk-demo-hoteling
  #   is the worked example that EXERCISES a :run branch (rake check:browse) —
  #   because branching on :action would otherwise be silent: it matches
  #   nothing, so the toll never applies to a write and no error, log line or
  #   test says so. kiosk-server does not let it be silent: assigning a
  #   policy whose #challenge_for compares the verb against :action raises
  #   Kiosk::Server::Errors::ConfigurationError from
  #   `Kiosk.configure`, at boot, naming :run.
  # @param factors  [Factors] reputation inputs
  # @return [Hash{alg:, params:, count:}] challenge spec, or nil to serve without challenge
  #   (`count` is optional; the gate defaults it to 1 when omitted)
  def challenge_for(identity:, verb:, factors:)
    # example: always challenge unknown principals
    return nil if factors.settled_purchases_count.to_i >= 5
    { alg: "equihash", params: { n: 168, k: 7 }, count: 1 }
  end
end
```

The base `Policy` class returns `nil` for every request (never challenge).

### `Policies::RecentSpend` — one toll per session, by a chance that recent spend lowers

```ruby
c.reputation_policy = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
```

A session pays one proof at the Equihash gem's default params, with the chance
`max(0, (cap - spend) / cap)`. `spend` is what the customer spent here within
`within`, and `cap` is in whole currency units. So a customer with no spend
pays in every session, and a customer who spent `cap` or more pays in none.
The draw is made once for each customer in each token lifetime. Token
lifetimes are consecutive spans of `exp - iat` seconds from the Unix epoch, and
the token's `iat` selects its span. So every call made with one token, and every
new token issued to the customer in the same span, meets the same outcome.
An operator that takes no payment records each fulfilled visit with
`Kiosk::Visit.record!(user_id:, value_cents:)`, and the visit counts as spend.
A refund through `Kiosk::Server::PaymentClaim#refund` is not spend.

### `Policies::RateAndReputation` — EXAMPLE (providers replace this)

This is the shipped illustrative policy for the "scrape-vs-buy" pattern.
Providers are expected to **replace it wholesale** with a domain-specific policy.

Equihash has no continuous difficulty dial, so this policy escalates by **proof
count** (N×PoW), not a `d` knob. It returns `{alg:, params:, count:}`; the
`kiosk-server` gate turns `count` into that many independent challenges.

```ruby
policy = Kiosk::Reputation::Policies::RateAndReputation.new(
  proven_purchases_threshold: 5,    # settled purchases to be "proven"
  low_rate_threshold:         10,   # max req/min considered low-rate
  base_count:                 1,    # proofs demanded when challenging at all
  rate_count_step:            1,    # proof increment per rate_step req/min above threshold
  rate_step:                  10,   # req/min bucket size for rate escalation
  unproven_count_bonus:       1,    # extra proofs for principals with 0 purchases
  bad_proof_count_factor:     3,    # count += bad_proof_count * this factor
  count_min:                  1,
  count_max:                  10,
  equihash_n:                 168,  # matches Kiosk::Pow::Equihash defaults
  equihash_k:                 7
)

policy.challenge_for(
  identity: current_user,
  verb: :query,
  factors: Kiosk::Reputation::Factors.new(
    settled_purchases_count: 0,
    request_rate_per_min: 80,
    bad_proof_count: 0,
    # other fields nil
    kyc_level: nil, settled_purchases_cents: nil,
    account_age_seconds: nil, dispute_count: nil
  )
)
# => { alg: "equihash", params: { n: 168, k: 7 }, count: 9 }
```

Logic: serve without challenge only when ALL of — settled purchases ≥ threshold,
rate ≤ threshold, and bad_proof_count == 0. Otherwise compute `count` by
escalating for high rate, zero purchases, and bad-faith history (bad_proof_count
is multiplied by `bad_proof_count_factor` to escalate fast), clamped to
`[count_min, count_max]`.

Behind the `kiosk-server` gate this policy gets `Factors.empty`, because it
answers no `#within`. So there it asks `base_count + unproven_count_bonus`
proofs of every access token.

## Reputation hit on bad proof

When `Challenge.verify` returns `:bad_proof` (well-formed, unexpired,
correctly-bound proof but wrong nonce), `kiosk-server` calls the
`on_bad_proof` callback with the caller's `Kiosk::Identity`. The engine keeps
no count of wrong proofs and gives none to the policy. A host that uses the
signal records it in a store it owns.

This is the intended signal: a correct solver never submits a wrong nonce.
A `:bad_sig` (forged or wrong-request proof), `:expired` or `:bad_params`
(off-spec difficulty) does NOT trigger `on_bad_proof` — those can be honest
clock skew, a retry, or a challenge that outlived a difficulty change; no
evidence of bad faith.

## kiosk-server configuration

The server gate (`Kiosk::Server::PowGate`) reads these config slots:

| Config slot | Type | Default | Description |
|-------------|------|---------|-------------|
| `reputation_policy` | `Kiosk::Reputation::Policy` instance (or duck type) | `nil` | Policy that decides when and how hard to challenge. `nil` = never challenge (zero overhead). |
| `pow_secret` | String | required when policy is set | HMAC key for challenge signing. Load from env: `ENV.fetch("KIOSK_POW_SECRET")`. |
| `pow_ttl` | Integer (seconds) | `300` | Challenge validity window. |
| `on_bad_proof` | `(identity:) → void` callable | no-op | Called with the caller's `Kiosk::Identity` when a submitted proof has a wrong nonce. Record it in a store you own. |
| `pow_spent_store` | `#claim`/`#release`/`#spent?`/`#mark_spent` | `Kiosk::Server::PowSpentStores::ActiveRecord` (the `kiosk.pow_spent` table) | Tracks spent challenge ids so a proof is accepted once, across every process and deploy. See kiosk-server's README, "Multi-process deployments". |

```ruby
Kiosk.configure do |c|
  c.reputation_policy = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
  c.pow_secret        = ENV.fetch("KIOSK_POW_SECRET")
  c.pow_ttl           = 300
end
```

The engine supplies the factors. For a policy that answers `#within` (a window
in seconds), it fills `settled_purchases_count` and `settled_purchases_cents`
from the customer's own settlements and recorded visits in that window; for any
other policy the factors are `Factors.empty`.

The gate tolls once per access token: after one paid toll, every call made
with that token proceeds until the token expires (`c.access_token_ttl`,
default 3600 seconds).

## Honesty / guardrails

- **PoW is economic friction, not a wall.** A determined ASIC attacker still
  gets in at some cost; the point is to make free-riding cost more than buying.
  Combine it with a cheap path for genuine buyers: `RecentSpend` tolls a
  customer less often as their recent spend grows.
- **Reputation = a sum of factors the host supplies.** We ship tools and an
  example policy, not a mandated curve. Providers are expected to write
  domain-specific policies that reflect their actual trust signals.
- **The provider mandates the algorithm.** Clients comply or are denied — do
  not add a negotiation path.
- **Verify is cheap; the solve is the cost.** Equihash verify is a few ms + KB
  (memory is the asymmetry: a few KB to verify, against a solve the reference
  numpy solver runs in ~1.3 GiB at n=168 k=7 — that is THAT solver's
  sorted-nonce table, not a floor those params impose on every solver, since a
  memory-optimised solver trades the table for time, which is how Equihash
  200/9's real footprint fell to ~144 MB), so the gate can check every request
  — only *challenge* on suspicion/rate, since each challenge costs the client a
  real solve.
- **`Policies::RateAndReputation` is an example.** Its thresholds and
  proof-count curve are opinionated defaults, not recommendations. Providers
  replace it with a domain-specific policy.

## Installation

> **Not on RubyGems yet** — so every `gem` line below carries `github: "kiosk-hq/kiosk"`, which is what makes it copy-pasteable today. Publication status and the canonical install are stated once, in the monorepo README's [Install](https://github.com/kiosk-hq/kiosk#install) section.

```ruby
gem "kiosk-reputation",   github: "kiosk-hq/kiosk"
gem "kiosk-pow-equihash", github: "kiosk-hq/kiosk"   # default backend
# gem "kiosk-pow-argon2id", github: "kiosk-hq/kiosk" # legacy Argon2id backend, if you specifically want it
```

In a Rails app `kiosk-pow-equihash` registers itself as the `equihash`
backend at boot. Any other backend is registered with `Backends.register`.

## License

Apache-2.0. See [LICENSE.txt](LICENSE.txt).
