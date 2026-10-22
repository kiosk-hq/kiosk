# kiosk-reputation

Policy and challenge layer for Kiosk's proof-of-work system.

## Overview

`kiosk-reputation` decides *when* and *how hard* to challenge a request with a
proof-of-work, issues and verifies the signed challenge, and provides a
pluggable reputation policy interface.

**Pure Ruby — no dependency on kiosk-pow or kiosk-core.** A PoW backend registers
with `Kiosk::Reputation::Backends.register`. In a Rails app `kiosk-pow-equihash`
registers itself at boot; the host registers any other backend (see
[Installation](#installation)). This gem is backend-agnostic:
the shipped default is **equihash** (`kiosk-pow-equihash`); `kiosk-pow-argon2id`
provides Argon2id (legacy, registers as `argon2id`); `kiosk-pow-cuckoo` provides
Cuckatoo Cycle (opt-in, registers as `cuckatoo`). Each backend is built on
`kiosk-pow`, whose README tells how to add a backend.

## Protocol

### Challenge — HTTP 402 `pow_required`

When the provider's reputation policy decides to challenge a request, the server
responds with HTTP 402 instead of serving. The answer is an RFC 9457 problem
document (`application/problem+json`, accompanied by
`WWW-Authenticate: Kiosk-PoW realm="<issuer>"`) whose flat top-level `code` is
`pow_required` and which carries a **`challenges` array** (plural) as an
extension member — the policy demands `count` independent proofs (N×PoW). A
policy that asks for more than one proof gets one challenge per proof:

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
per solved challenge. The protocol makes most calls GETs (a query is
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

The challenge is stateless, so `alg`/`params` travel in the protocol and come back
from the client. The HMAC sig proves *we minted them*; it does **not** prove they
are still the difficulty this server demands. Pass `expect:` — the spec the
caller just re-derived from its own configuration for this request — and
`verify` refuses any challenge naming other parameters, however valid its sig:

```ruby
Kiosk::Reputation::Challenge.verify(
  challenge: challenge, nonce: solution,
  request_fingerprint: fp, secret: secret, now: Time.now.to_i,
  expect: { alg: "equihash", params: { n: 168, k: 7 } }   # from YOUR config, not the protocol
)
```

Two things this buys: a challenge minted just before a difficulty raise stops
being solvable at the old cheap parameters for the rest of its TTL, and a leaked
HMAC secret cannot let a self-signed `{n: 8, k: 1}` challenge turn the toll
off — the toll degrades rather than vanishing. `kiosk-server`'s gate always
passes `expect:`; `Challenge.verify` skips the check when it is omitted.

Comparison uses the same canonical `k=v` rendering the sig covers, so key order,
Symbol-vs-String keys and `168` vs `"168"` are all equal — it rejects a different
difficulty and nothing else. `:bad_params` means **re-challenge, not bad faith**:
`kiosk-server` releases the challenge id and answers 402 at current params
(never 403).

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

Stateless, request-bound signed challenge. The caller (`kiosk-server`) maintains a
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

Immutable bundle of reputation inputs per request. Both fields may be nil.

```ruby
Kiosk::Reputation::Factors.new(
  settled_purchases_count: 3,            # settlements and visits in the window
  settled_purchases_cents: 65_00         # their value in cents, less refunds
)

Kiosk::Reputation::Factors.empty         # both fields nil
```

### `Policy` (base)

```ruby
class MyPolicy < Kiosk::Reputation::Policy
  # @param identity [Object]  opaque identity value from the host
  # @param verb     [Symbol]  the PROTOCOL command — :query, :run or :pay. Not the
  #   declaration name: a verb a handler declares as `kind :action` in
  #   kiosk-server arrives here as :run (`Kiosk::Handler` serves an action
  #   as `:run`), so branch on :run rather than on :action. The protocol
  #   states the same mapping in its Reputation section. Branching on :action
  #   would otherwise be silent: it matches
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

### `Policies::RecentSpend` — a toll on every Nth call, and spend makes N larger

```ruby
c.reputation_policy = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
```

An account pays one proof at the Equihash gem's default params on every Nth
tolled call: `N = ceil(10 / share)`, with `share = max(0, (cap - spend) / cap)`.
`spend` is what the customer spent here within `within`, and `cap` is in whole
currency units. So with no spend N is 10; at 25, 50 and 75 percent of the cap
it is 14, 20 and 40; at `cap` or more no call pays. The engine counts the
calls of each account since its last paid proof. The assistants bound to one
account share the count and the spend, and a new access token keeps the count.
An operator that takes no payment records each fulfilled visit with
`Kiosk::Visit.record!(user_id:, value_cents:)`, and the visit counts as spend.
A refund through `Kiosk::Server::PaymentClaim#refund` is not spend.

## kiosk-server configuration

The server gate (`Kiosk::Server::PowGate`) reads these config slots:

| Config slot | Type | Default | Description |
|-------------|------|---------|-------------|
| `reputation_policy` | `Kiosk::Reputation::Policy` instance (or duck type) | `nil` | Policy that decides when and how hard to challenge. `nil` = never challenge (zero overhead). |
| `pow_secret` | String | required when policy is set | HMAC key for challenge signing. Load from env: `ENV.fetch("KIOSK_POW_SECRET")`. |
| `pow_ttl` | Integer (seconds) | `300` | Challenge validity window. |
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
from the customer's settlements and recorded visits in that window. The
settlements that an assistant made before a binding moved it to the account
count too. It fills `calls_since_proof` with the account's tolled calls since
its last paid proof, this call included. For any other policy the factors are
`Factors.empty`. A paid proof sets the count back to zero.

## Honesty / guardrails

- **PoW is economic friction, not a wall.** A determined ASIC attacker still
  gets in at some cost; the point is to make free-riding cost more than buying.
  Combine it with a cheap path for genuine buyers: `RecentSpend` tolls a
  customer less often as their recent spend grows.
- **Reputation = a sum of factors the host supplies.** We ship tools and one
  policy, not a mandated curve. Providers are expected to write
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

## Installation

```ruby
gem "kiosk-reputation"
gem "kiosk-pow-equihash"   # default backend
# gem "kiosk-pow-argon2id" # legacy Argon2id backend, if you specifically want it
```

In a Rails app `kiosk-pow-equihash` registers itself as the `equihash`
backend at boot. Any other backend is registered with `Backends.register`.

## License

Apache-2.0. See [LICENSE.txt](LICENSE.txt).
