# kiosk-reputation

Policy + wire-challenge layer for Kiosk's proof-of-work system.

## Overview

`kiosk-reputation` decides *when* and *how hard* to challenge a request with a
proof-of-work, issues and verifies the signed wire challenge, and provides a
pluggable reputation policy interface.

**Pure Ruby — no dependency on kiosk-pow or kiosk-core.** PoW backends
register themselves via `Kiosk::Reputation::Backends.register`. This gem is
backend-agnostic: `kiosk-pow` registers Argon2id; `kiosk-pow-cuckoo` (Phase 2)
will register Cuckoo Cycle.

## Wire protocol

See the [design spec](../../docs/superpowers/specs/2026-06-26-r2-pow-reputation.md)
and [ADR-0001](../../docs/adr/0001-proof-of-work-memory-hard-provider-mandated.md).

### Challenge (`pow_required` / HTTP 402)

```json
{
  "id":     "<uuid>",
  "alg":    "argon2id",
  "params": { "m": 65536, "t": 1, "p": 1, "d": 6 },
  "salt":   "<base64 of 16 raw bytes, fresh per challenge>",
  "exp":    1750000600,
  "sig":    "<HMAC-SHA256 hex over (id|alg|params|salt|exp|request_fingerprint)>"
}
```

- `alg` + `params` are **mandated** — no client negotiation field.
- `sig` binds the challenge to the original request; a proof cannot be replayed against a different call.
- `exp` is short (e.g. 300 s) — bounds replay window.

### Proof (client re-sends the same request with `pow`)

```json
{ "pow": { "challenge": { ...verbatim... }, "nonce": "<solution>" } }
```

## Anti-DoS invariant: cheap checks before the expensive backend eval

`Challenge.verify` enforces this order — always:

1. Recompute + compare HMAC sig (constant-time) → `:bad_sig` (tampered / wrong request binding)
2. Expiry check → `:expired`
3. **Only then**: one backend eval (one Argon2id hash, costs `m` KiB) → `:ok` / `:bad_proof`

Floods of forged or expired proofs are rejected at step 1/2 without burning an
Argon2id memory eval. This is not optional; it is tested.

## Components

### `Backends`

```ruby
Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
Kiosk::Reputation::Backends.fetch("argon2id")  # => Kiosk::Pow
Kiosk::Reputation::Backends.known              # => ["argon2id"]
```

### `Challenge`

```ruby
challenge = Kiosk::Reputation::Challenge.issue(
  alg: "argon2id",
  params: { m: 65_536, t: 1, p: 1, d: 6 },
  request_fingerprint: "sha256:...",
  secret: "provider-hmac-key",
  ttl: 300
)
# => { id:, alg:, params:, salt: <base64>, exp:, sig: }

result = Kiosk::Reputation::Challenge.verify(
  challenge: challenge,
  nonce: "42",
  request_fingerprint: "sha256:...",
  secret: "provider-hmac-key",
  now: Time.now.to_i
)
# => :ok | :bad_sig | :expired | :bad_proof
```

**Note:** `Challenge` is stateless. The caller (`kiosk-server`) must maintain a
spent-id set (TTL ≤ `challenge[:exp]`) to prevent replay of a valid proof.

### `Factors`

```ruby
factors = Kiosk::Reputation::Factors.new(
  settled_purchases_count: 0,
  request_rate_per_min: 120,
  bad_proof_count: 2,
  # all fields are nullable:
  kyc_level: nil, settled_purchases_cents: nil,
  account_age_seconds: nil, dispute_count: nil
)

Kiosk::Reputation::Factors.empty  # all-nil convenience constructor
```

### `Policy` (base)

```ruby
class MyPolicy < Kiosk::Reputation::Policy
  def challenge_for(identity:, verb:, factors:)
    # return { alg: "argon2id", params: Backends.fetch("argon2id").params(d: 6) }
    # or nil to serve without challenge
  end
end
```

### `Policies::RateAndReputation` (EXAMPLE — providers replace this)

```ruby
policy = Kiosk::Reputation::Policies::RateAndReputation.new(
  proven_purchases_threshold: 5,
  low_rate_threshold: 10,
  base_d: 5,
  bad_proof_d_factor: 3,
  d_max: 14
)

policy.challenge_for(
  identity: current_user,
  verb: :query,
  factors: Factors.new(settled_purchases_count: 0, request_rate_per_min: 80, ...)
)
# => { alg: "argon2id", params: { m: 65536, t: 1, p: 1, d: 12 } }
```

## Honesty / guardrails

- PoW is **economic friction, not a wall**. A determined ASIC attacker still
  gets in at some cost; the point is to make free-riding cost more than buying.
  Combine with reputation + the cheap-for-genuine-buyers path.
- The provider **mandates** the algorithm; clients comply or are denied — do not
  add a negotiation path.
- Default Argon2id verify costs `m` KiB of memory — only challenge on
  suspicion/rate, not on every cheap call.
- `Policies::RateAndReputation` is an **example**. Providers are expected to
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
