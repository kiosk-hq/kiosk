# kiosk-pow-cuckoo

Cuckatoo-Cycle proof-of-work backend for [Kiosk](https://kiosk.tech).

> **Shelved / optional.** The shipped default PoW backend is
> [`kiosk-pow-equihash`](https://github.com/kiosk-hq/kiosk/tree/main/kiosk-pow-equihash) — one PoW backend, Equihash.
> Cuckatoo meets the asymmetric-verify bar, but needs
> ~4 GiB solves and heavier solver tooling (this gem ships only a toy solver),
> so it is not the default. It stays in the repo as an opt-in backend and may
> return as a first-class extension; it is no longer wired into demos or docs.

## What this is

An optional (shelved) PoW backend with a large solve:verify asymmetry — solving
requires finding a cycle in a large random bipartite graph (gigabytes of RAM,
seconds of CPU), while verifying is a handful of operations: `proofsize` SipHash
evaluations plus a cycle-walk (no wall-clock verify figure is benchmarked here).

**This gem ships the VERIFIER only.**  The verifier is production-correct,
validated against Grin's Cuckatoo29 L=42 known-answer test vector.

The included Python solver (`solve_cuckoo.py`) is a **REFERENCE/TOY solver**
for small edgebits and reduced proofsize only — see Solver section below.

## Algorithm: Cuckatoo Cycle

- Graph size: `N = 2^edgebits` edges in a random bipartite graph
- Edge `i` connects `U(i) = siphash(2i) mod N` to `V(i) = siphash(2i+1) mod N`
- Proof: `proofsize` strictly-ascending edge indices forming a single cycle
  on node-pairs (`node >> 1`)
- Keys: `blake2b-256(salt ‖ LE32(header_nonce))` split into four LE-u64 words

SipHash uses Cuckatoo's **non-standard initialization** (keys feed directly into
`v0..v3` without XOR-ing the 0x736f6d65... magic constants from the standard
SipHash spec).

## Implementation

- **BLAKE2b-256**: pure Ruby from the public-domain [BLAKE2 spec](https://www.blake2.net/blake2.pdf).
- **SipHash-2-4**: pure Ruby from the [public-domain SipHash spec](https://131002.net/siphash/siphash.pdf),
  with Cuckatoo's non-standard init.
- No native extensions, no GPL code, no Tromp repository code.
- License: Apache-2.0.

## Known-answer validation

The verifier is validated against Grin's Cuckatoo29 CI test vector:
- `edgebits=29`, header = 80 zero bytes keyed with `nonce=20`, `proofsize=42`
- 42-cycle accepted; five categories of bad inputs rejected

Run: `bundle exec rspec` — all green.

## API

```ruby
# Challenge params (proofsize defaults to 42; pass proofsize: 12 for the toy demo)
params = Kiosk::Pow::Cuckoo.params(edgebits: 29, proofsize: 42)
# => { edgebits: 29, proofsize: 42, target: nil }

# Verify a proof (composite nonce: header_nonce + cycle)
# -- This is the ONE deviation from kiosk-pow's scalar nonce: --
# The wire proof is { header_nonce: <u32>, cycle: [proofsize ints, ascending] }
# kiosk-reputation passes this composite object unchanged to .verify.
Kiosk::Pow::Cuckoo.verify(
  salt:   raw_salt_bytes,
  params: params,
  nonce:  { header_nonce: 20, cycle: [e0, e1, ..., e41] }
)
# => true / false

# Lower-level: verify cycle with pre-derived keys
keys = Kiosk::Pow::Cuckoo.blake2b256(header).unpack("Q<4")
Kiosk::Pow::Cuckoo.verify_cycle(keys: keys, edgebits: 29, cycle: cycle, proofsize: 42)
```

## Wire interface: composite nonce

Unlike `kiosk-pow` (Argon2id, scalar nonce), Cuckatoo proofs are composite:

```json
{
  "challenge": { "id": "...", "alg": "cuckatoo", "params": {...}, "salt": "...", "exp": ..., "sig": "..." },
  "nonce":     { "header_nonce": 1, "cycle": [12, 362, 383, ...] }
}
```

`kiosk-reputation`'s `Challenge.verify` passes the entire `nonce` field through
to the backend's `.verify(salt:, params:, nonce:)` unchanged.  Confirm: it uses
`nonce = pow[:nonce] || pow["nonce"]` and does NOT assume `nonce` is a String.

## Solver

### Shipped Python solver (`solve_cuckoo.py`) — REFERENCE/TOY ONLY

`solve_cuckoo.py` is a **pure-Python + numpy reference solver for small
edgebits and reduced proofsize only**.

| Property | Value |
|----------|-------|
| Language | Python 3 + numpy |
| Status   | Reference/toy — NOT production |
| Purpose  | Mechanism demonstration at small sizes |
| Tested at | edgebits=10, proofsize=12 (~1 second) |
| Memory guard | Built-in `_enforce_memory_budget`: refuses oversized edgebits |
| Safety wrapper | `KIOSK_POW_MAX_BYTES=536870912 timeout 30 nice -n 19 python3 solve_cuckoo.py` |

**Why edgebits=10 for proofsize=12:**
A valid Cuckatoo proofsize=12 cycle exists in the bipartite pair-graph only when
the pair-graph girth ≤ 12. With N/2 = 2^(edgebits-1) pair values per side and
mean pair-degree 2, the expected girth is approximately log₂(N/2). For
proofsize=12, this requires edgebits ≤ 12-13. At edgebits=10 (N/2=512) cycles
exist and solve in ~1 second. At edgebits ≥ 14, 12-cycles essentially vanish.

**Cannot solve production Cuckatoo** (L=42, edgebits≥29). Pure Python cannot
allocate or search the required ~1 GB+ graph in usable time. Production requires
a native solver (C/C++ like Tromp's `lean`/`mean` miner).

### Cross-impl parity gate

```bash
cd kiosk-pow-cuckoo
bundle exec rake solve_parity
```

Runs `solve_cuckoo.py` at the toy demo params (edgebits=10, proofsize=12) under
the safety wrapper, then calls the Ruby `Kiosk::Pow::Cuckoo.verify` and asserts
the proof is accepted.  This proves solver output is accepted by the validated
verifier.

### Production solver (out of scope for this gem)

Production Cuckatoo (edgebits≥29, proofsize=42) requires clients with a native
solver.  Options:
- **Tromp's C miner** (`lean`/`mean`, `simple`): fast, FAIR-MINING/GPLv2+ license
- **GPU solvers**: faster still; CUDA-only
- Provider mandates the algorithm; clients that cannot solve are denied

## Difficulty target

An optional `target` (Integer, 256-bit) can be added to params to tighten
difficulty beyond the base cycle requirement:

```ruby
params = Kiosk::Pow::Cuckoo.params(edgebits: 29, target: (2**256 - 1) / 100)
```

When set, the verifier additionally checks:
```
blake2b-256(sorted_cycle_edges_as_LE_u64) < target
```

## Toy mechanism demo

**TOY MECHANISM DEMO — proofsize 12 at edgebits 10; NOT production difficulty.**

Cuckatoo is no longer wired into any demo app. The solve → verify loop at the
toy params is exercised by this gem's cross-impl parity gate (see the Solver
section above):

```bash
cd kiosk-pow-cuckoo
bundle exec rake solve_parity
```

Runs the Python reference solver, then asserts the Ruby verifier accepts its
proof.

## Caveats

- Cuckatoo is NOT ASIC-proof (1 GB-SRAM ASICs exist for edgebits=31+). The
  provider mandates it; clients that cannot solve are denied. This is
  intentional: it raises the cost of abuse.
- **Equihash** (`kiosk-pow-equihash`) is the shipped default.
  Argon2id (`kiosk-pow`) remains as a legacy backend. Use Cuckatoo only when the
  extreme solve:verify asymmetry (GB-RAM solver vs. a few-hash verifier) is
  specifically required.
- `proofsize < 42` is a deviation from production Cuckatoo (L=42 per Grin/Tromp
  spec). The toy demo (L=12) demonstrates the mechanism only.
- `edgebits < 29` is suitable only for testing; production Grin uses edgebits 29.
