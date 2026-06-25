# kiosk-pow

Argon2id memory-hard proof-of-work backend for the [Kiosk](https://kiosk.tech) framework.

## What it does

Providers can demand a proof-of-work on any verb to conserve compute against scraping and flooding.  `kiosk-pow` ships both sides:

- **Ruby verify** (`Kiosk::Pow.verify`) — one Argon2id eval per proof, no loop.  Costs `m` KiB memory (the provider's ASIC-resistance knob); the lever is `2^d` (solve ≈ 2^d evals, verify = 1).
- **Python solver** (`solve.py`) — an assistant runs this in its sandbox when it receives a `pow_required` challenge.  Pure `argon2-cffi`, no exotic deps.

Both sides produce byte-identical Argon2id digests (verified by `rake parity`).

## The canonical PoW computation

```
Argon2id(password = str(nonce),      # decimal ASCII, e.g. "0", "1234"
         salt     = raw_salt_bytes,  # ≥ 8 bytes; wire base64 decoded upstream
         m_cost   = params[:m],      # KiB (default 65 536 = 64 MiB)
         t_cost   = params[:t],      # iterations (default 1)
         p        = params[:p],      # parallelism (default 1)
         version  = 0x13,            # ARGON2_VERSION_13
         hash_len = 32)
```

A nonce is valid iff `leading_zero_bits(digest) >= params[:d]`.

## Difficulty tiers (guidance)

| `d` | solve time (est.) | use case |
|----:|:-----------------:|:---------|
| 0   | instant           | no challenge (policy returns nil) |
| 5–6 | 2–4 s             | light friction for unproven principals |
| 8   | 20–40 s           | medium throttle |
| 11  | 3–6 min           | hard throttle for high-suspicion/high-rate |

Solve time depends on `m` and the assistant's hardware.  Defaults: `m = 65 536` KiB (64 MiB), `t = 1`, `p = 1`.

## Usage

```ruby
gem "kiosk-pow"
```

```ruby
require "kiosk/pow"

params = Kiosk::Pow.params(d: 8)           # { m: 65_536, t: 1, p: 1, d: 8 }
salt   = SecureRandom.bytes(16)            # fresh per challenge

# Provider verify (one eval):
Kiosk::Pow.verify(salt:, params:, nonce: submitted_nonce)  # => true / false

# Raw digest (32 bytes):
Kiosk::Pow.digest(salt:, params:, nonce: "42")
```

## Python solver

```bash
pip install argon2-cffi
python3 solve.py '{"salt":"<base64>","params":{"m":65536,"t":1,"p":1,"d":8}}'
# => {"nonce": "73821"}
```

## Cross-implementation parity check

```bash
bundle exec rake parity
```

Computes the same Argon2id digest in Ruby and Python, asserts hex-equal, then runs `solve.py` on a small challenge and asserts Ruby `verify` accepts the result.

## Honesty / guardrails

- PoW is **economic friction, not a wall**.  A determined ASIC attacker still gets in; the point is to make free-riding cost more than buying.  Combine with `kiosk-reputation` for the full picture.
- The provider **mandates** `alg` + `params`; clients comply or are denied.  No negotiation path.
- Default verify costs `m` KiB memory — only challenge on suspicion/rate, not on every cheap call.
