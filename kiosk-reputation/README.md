# kiosk-reputation

Policy and wire-challenge layer for Kiosk's proof-of-work system.

## Overview

`kiosk-reputation` decides *when* and *how hard* to challenge a request with a
proof-of-work, issues and verifies the signed wire challenge, and provides a
pluggable reputation policy interface.

**Pure Ruby — no dependency on kiosk-pow or kiosk-core.** PoW backends
register themselves via `Kiosk::Reputation::Backends.register`. This gem is
backend-agnostic: `kiosk-pow` registers Argon2id; `kiosk-pow-cuckoo` (Phase 2)
will register Cuckoo Cycle.

## Wire protocol

### Challenge — HTTP 402 `pow_required`

When the provider's reputation policy decides to challenge a request, the server
responds with HTTP 402 instead of serving:

```json
{
  "ok": false,
  "error": {
    "code":    "pow_required",
    "message": "proof-of-work required",
    "challenge": {
      "id":     "<uuid>",
      "alg":    "argon2id",
      "params": { "m": 65536, "t": 1, "p": 1, "d": 6 },
      "salt":   "<base64 of 16 raw bytes, fresh per challenge>",
      "exp":    1750000600,
      "sig":    "<HMAC-SHA256 hex over canonical(id|alg|params|salt|exp|request_fingerprint)>"
    }
  }
}
```

Key properties:

- `alg` + `params` are **mandated** — no client negotiation field.
- `salt` is fresh per challenge — prevents precomputation / rainbow tables.
- `sig` is HMAC-SHA256 (provider `pow_secret`) over the challenge fields **and
  a fingerprint of the original request** (`SHA256(command + "\n" + canonical_json(body))`).
  The challenge is stateless-verifiable (no server storage needed to trust it)
  and bound to that specific request (a proof cannot be replayed against a
  different call).
- `exp` is short (default 300 s) — bounds replay window.

### Proof — client re-sends the same request with `pow`

```json
{
  "command": "query",
  "body":    { "name": "menu_by_restaurant", "restaurant": "Mamma Pizza" },
  "pow":     { "challenge": { ...verbatim... }, "nonce": "<solution>" }
}
```

The `pow` field is a sibling of `body` and is excluded from the request
fingerprint — the fingerprint at issue time (no `pow`) and verify time (with
`pow`) are identical by design.

## Anti-DoS invariant: cheap checks before the expensive backend eval

`Challenge.verify` enforces this order — always:

1. Recompute + compare HMAC sig (constant-time `OpenSSL.fixed_length_secure_compare`)
   → `:bad_sig` (tampered, wrong request binding, or forged challenge)
2. Expiry check (`exp > now`) → `:expired`
3. **Only then**: one backend eval (one Argon2id hash, costs `m` KiB) → `:ok` / `:bad_proof`

Floods of forged or expired proofs are rejected at steps 1/2 without burning an
Argon2id memory eval. This is not optional; it is tested.

## Components

### `Backends`

Registry mapping algorithm names to PoW backend objects.

```ruby
Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
Kiosk::Reputation::Backends.fetch("argon2id")   # => Kiosk::Pow
Kiosk::Reputation::Backends.known               # => ["argon2id"]
```

A backend must respond to:
- `.params(d:, **) → Hash` — build challenge params for a difficulty tier
- `.verify(salt:, params:, nonce:) → Boolean` — verify a submitted proof

### `Challenge`

Stateless, request-bound wire challenge. The caller (`kiosk-server`) maintains a
spent-id set (TTL ≤ `challenge[:exp]`) to prevent replay of a valid proof —
`Challenge` itself does not track spent ids.

```ruby
challenge = Kiosk::Reputation::Challenge.issue(
  alg:                  "argon2id",
  params:               { m: 65_536, t: 1, p: 1, d: 6 },
  request_fingerprint:  "sha256:...",
  secret:               "provider-hmac-key",
  ttl:                  300            # seconds; exp = Time.now.to_i + ttl
)
# => { id:, alg:, params:, salt: <base64>, exp:, sig: }

result = Kiosk::Reputation::Challenge.verify(
  challenge:            challenge,
  nonce:                "73821",
  request_fingerprint:  "sha256:...",
  secret:               "provider-hmac-key",
  now:                  Time.now.to_i
)
# => :ok | :bad_sig | :expired | :bad_proof
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
  # @param verb     [Symbol]  :query, :run, :pay, …
  # @param factors  [Factors] reputation inputs
  # @return [Hash{alg:, params:}] challenge spec, or nil to serve without challenge
  def challenge_for(identity:, verb:, factors:)
    # example: always challenge unknown principals
    return nil if factors.settled_purchases_count.to_i >= 5
    { alg: "argon2id", params: Kiosk::Reputation::Backends.fetch("argon2id").params(d: 6) }
  end
end
```

The base `Policy` class returns `nil` for every request (never challenge).

### `Policies::RateAndReputation` — EXAMPLE (providers replace this)

This is the shipped illustrative policy for the "scrape-vs-buy" pattern.
Providers are expected to **replace it wholesale** with a domain-specific policy.

```ruby
policy = Kiosk::Reputation::Policies::RateAndReputation.new(
  proven_purchases_threshold: 5,    # settled purchases to be "proven"
  low_rate_threshold:         10,   # max req/min considered low-rate
  base_d:                     5,    # starting d when challenging
  rate_d_step:                1,    # d increment per rate_step req/min above threshold
  rate_step:                  10,   # req/min bucket size for rate escalation
  unproven_d_bonus:           2,    # extra d for principals with 0 purchases
  bad_proof_d_factor:         3,    # d += bad_proof_count * this factor
  d_min:                      3,
  d_max:                      14
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
# => { alg: "argon2id", params: { m: 65536, t: 1, p: 1, d: 12 } }
```

Logic: serve without challenge only when ALL of — settled purchases ≥ threshold,
rate ≤ threshold, and bad_proof_count == 0. Otherwise compute `d` by escalating
for high rate, zero purchases, and bad-faith history (bad_proof_count is
multiplied by `bad_proof_d_factor` to escalate fast).

## Reputation hit on bad proof

When `Challenge.verify` returns `:bad_proof` (well-formed, unexpired,
correctly-bound proof but wrong nonce), `kiosk-server` calls the
`on_bad_proof` callback. The host increments the principal's `bad_proof_count`
there. The example policy then escalates difficulty fast on subsequent requests
from the same principal.

This is the intended signal: a correct solver never submits a wrong nonce.
A `:bad_sig` (forged or wrong-request proof) does NOT trigger `on_bad_proof` —
it could be an honest clock skew or retry; no evidence of bad faith.

## kiosk-server configuration

The server gate (`Kiosk::Server::PowGate`) reads these config slots:

| Config slot | Type | Default | Description |
|-------------|------|---------|-------------|
| `reputation_policy` | `Kiosk::Reputation::Policy` instance (or duck type) | `nil` | Policy that decides when and how hard to challenge. `nil` = never challenge (zero overhead). |
| `pow_secret` | String | required when policy is set | HMAC key for challenge signing. Load from env: `ENV.fetch("KIOSK_POW_SECRET")`. |
| `pow_ttl` | Integer (seconds) | `300` | Challenge validity window. |
| `reputation_factors` | `(identity:, verb:) → Factors` callable | returns `Factors.empty` | Host-supplied callable that gathers reputation context per request. |
| `on_bad_proof` | `(identity:) → void` callable | no-op | Called when a submitted proof has a wrong nonce. Increment `bad_proof_count` here. |
| `pow_spent_store` | `PowSpentStore`-compatible | in-process TTL store | Tracks spent challenge ids to prevent proof replay. Override with a shared store (e.g. Redis-backed) in multi-process deployments. |

```ruby
Kiosk.configure do |c|
  c.reputation_policy = Kiosk::Reputation::Policies::RateAndReputation.new
  c.pow_secret        = ENV.fetch("KIOSK_POW_SECRET")
  c.pow_ttl           = 300
  c.reputation_factors = ->(identity:, verb:) {
    Kiosk::Reputation::Factors.new(
      settled_purchases_count: identity.settled_purchases_count,
      request_rate_per_min:    RateStore.rate(identity.id),
      bad_proof_count:         identity.bad_proof_count,
      kyc_level:               identity.kyc_level,
      settled_purchases_cents: nil,
      account_age_seconds:     nil,
      dispute_count:           nil
    )
  }
  c.on_bad_proof = ->(identity:) { identity.increment!(:bad_proof_count) }
end
```

## Honesty / guardrails

- **PoW is economic friction, not a wall.** A determined ASIC attacker still
  gets in at some cost; the point is to make free-riding cost more than buying.
  Combine with the cheap-for-genuine-buyers path (proven principals pass through
  unchallenged when rate is low).
- **Reputation = a sum of factors the host supplies.** We ship tools and an
  example policy, not a mandated curve. Providers are expected to write
  domain-specific policies that reflect their actual trust signals.
- **The provider mandates the algorithm.** Clients comply or are denied — do
  not add a negotiation path.
- **Default Argon2id verify costs `m` KiB of memory** — only challenge on
  suspicion/rate, not on every cheap call.
- **`Policies::RateAndReputation` is an example.** Its thresholds and
  d-escalation curve are opinionated defaults, not recommendations. Providers
  replace it with a domain-specific policy.

## Installation

```ruby
gem "kiosk-reputation"
gem "kiosk-pow"  # registers "argon2id" backend
```

```ruby
# config/initializers/kiosk_pow.rb
require "kiosk/pow"
Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
```

## License

Apache-2.0. See [LICENSE.txt](LICENSE.txt).
