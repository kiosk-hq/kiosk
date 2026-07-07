# kiosk-pow

Argon2id memory-hard proof-of-work backend for the [Kiosk](https://kiosk.tech) framework.

## What it is

`kiosk-pow` is the default PoW backend for Kiosk. It implements a
**search-form Argon2id PoW**: a client finds the smallest nonce `n ≥ 0` such
that `Argon2id(password=str(n), salt=raw_salt, ...)` has ≥ `d` leading zero
bits. The provider verifies by computing **one** Argon2id eval — the solve:verify
lever is exactly `2^d`.

Providers can demand this PoW on any `/kiosk/{query,run,pay}` verb at their discretion,
via `kiosk-reputation`'s policy layer. `kiosk-pow` ships both sides:

- **Ruby verify** (`Kiosk::Pow.verify`) — one Argon2id eval, no loop.
- **Python solver** (`solve.py`) — an assistant runs this in its sandbox when
  it receives a `pow_required` challenge. Pure `argon2-cffi`, no exotic deps.

Both sides produce byte-identical Argon2id digests (verified by `rake parity`).

## Ruby API

```ruby
# Challenge params for a difficulty tier:
Kiosk::Pow.params(d: 8)
# => { m: 65_536, t: 1, p: 1, d: 8 }

# Check one proof (one Argon2id eval — no loop):
Kiosk::Pow.verify(salt: raw_bytes, params: { m: 65_536, t: 1, p: 1, d: 8 }, nonce: "73821")
# => true / false

# Raw 32-byte digest:
Kiosk::Pow.digest(salt: raw_bytes, params: { m: 65_536, t: 1, p: 1, d: 8 }, nonce: "0")
```

### Constants and defaults

| Symbol | Value | Meaning |
|--------|-------|---------|
| `Kiosk::Pow::NAME` | `"argon2id"` | Algorithm name advertised in the wire challenge |
| `m` default | `65_536` KiB (64 MiB) | ASIC-resistance knob; sets verify cost and solve cost equally |
| `t` default | `1` | Iterations |
| `p` default | `1` | Parallelism |
| `d` | provider-chosen | Required leading zero bits; escalation knob; solve ≈ `2^d` evals |

## The canonical PoW computation

Both the Ruby verifier and the Python solver compute the same primitive:

```
Argon2id(
  password = str(nonce),       # decimal ASCII string, e.g. "0", "73821"
  salt     = raw_salt_bytes,   # ≥ 8 raw bytes; wire base64 decoded upstream
  m_cost   = params[:m],       # memory in KiB (default 65 536 = 64 MiB)
  t_cost   = params[:t],       # iterations (default 1)
  p        = params[:p],       # parallelism (default 1)
  version  = 0x13,             # ARGON2_VERSION_13 (19) — hardcoded both sides
  hash_len = 32                # 32-byte output
)
```

A nonce is valid iff `leading_zero_bits(digest) >= params[:d]`.

Ruby uses `Argon2::Ext.argon2id_hash_raw` (libargon2, always version `0x13`).
Python uses `argon2.low_level.hash_secret_raw(..., version=19)` (`argon2-cffi`).
Version `19` decimal == `0x13` hex — byte-identical output.

## Wire challenge params

The `params` object in the challenge carries exactly four integer keys:

| Key | Type | Meaning |
|-----|------|---------|
| `m` | Integer | Memory in KiB |
| `t` | Integer | Iterations |
| `p` | Integer | Parallelism |
| `d` | Integer | Required leading zero bits |

## Python solver

```bash
pip install argon2-cffi

python3 solve.py '{"salt":"<base64>","params":{"m":65536,"t":1,"p":1,"d":8}}'
# stdout: {"nonce": "73821"}
```

`solve.py` accepts the challenge JSON as `sys.argv[1]` or reads it from stdin.
It only reads `"salt"` and `"params"` from the challenge — the other fields
(`id`, `alg`, `exp`, `sig`) are ignored, so the full challenge object is safe
to pass directly.

For agent skill guidance see `SKILL.md`.

## Difficulty tiers (guidance)

Solve time depends on `m` and the assistant's hardware. Defaults: `m = 65 536`
KiB (64 MiB), `t = 1`, `p = 1`.

| `d` | Expected solve time | Typical use |
|----:|:-------------------:|:------------|
| 0   | instant             | no challenge (policy returns nil) |
| 5–6 | 2–4 s               | light friction for unproven principals |
| 8   | 20–40 s             | medium throttle |
| 11  | 3–6 min             | hard throttle for high-suspicion/high-rate |

These are guidance on server-class compute; actual times vary.

## Cross-implementation parity check

```bash
bundle exec rake parity
```

Computes the same Argon2id digest in Ruby and Python, asserts hex-equal, then
runs `solve.py` on a small challenge and asserts Ruby `verify` accepts the
result. Run this after any change to either implementation.

## Installation

```ruby
gem "kiosk-pow"
```

```ruby
require "kiosk/pow"

# Register with kiosk-reputation (if using the policy layer):
Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
```

## Honesty / guardrails

- **PoW is economic friction, not a wall.** A determined ASIC attacker still
  gets in; the point is to make free-riding cost more than buying. Combine with
  `kiosk-reputation` for the full picture.
- **The provider mandates `alg` + `params`.** Clients comply or are denied.
  There is no negotiation path — do not add one.
- **Default verify costs `m` KiB of memory** — one full Argon2id eval.
  Only challenge on suspicion/rate, not on every cheap call. The challenge
  should protect a value worth more than the verify cost.
- **`m` is the ASIC-resistance knob; `d` is the difficulty knob.** Raising `m`
  raises solve and verify equally (lever unchanged). Raising `d` raises solve
  exponentially while verify stays one eval.

## License

Apache-2.0. See [LICENSE.txt](LICENSE.txt).
