# Kiosk::Pow::Equihash

Memory-hard proof-of-work for Kiosk. Default PoW backend.

Its job is a **cheap-to-verify metered toll**, not a hardware equaliser.
Equihash is not ASIC- or GPU-proof — it was ASIC'd on Zcash (Antminer Z9/Z15)
and GPUs solve it well (the Wagner sort/collide parallelises, and it is
memory-bandwidth-bound). What it buys the provider is a few-KB, ~22 ms
`verify` against a solve that costs the client real time and memory, plus an
`N×PoW` count knob. Abuse resistance comes from reputation and caps
(PoW = metered pricing, not a hardware wall).

## Install

Default does not mean bundled: neither `kiosk-server` nor `kiosk-all` depends
on a PoW backend, so an origin that gates on PoW adds this gem itself.

```ruby
gem "kiosk-pow-equihash"
```

The verifier is pure Ruby. Its one runtime dependency is `kiosk-pow`, the
pure-Ruby base that holds BLAKE2b-256. It needs no `kiosk-core`, no Rails and no
native extension. In a Rails app the gem registers itself as the
`equihash` backend when the app boots. The registry lives in `kiosk-reputation`,
which an origin adds to its Gemfile the same way. Outside Rails, register it
yourself:

```ruby
require "kiosk/pow/equihash"

# Kiosk::Pow::Equihash::NAME == "equihash"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
```

That is the whole install for an **operator**, and it is deliberately this
small: verifying is what a served request does. **Solving is the caller's
side**, and it is the only part with a prerequisite outside Ruby — `solve.py`
ships inside the package and needs **`python3` with `numpy`**
(`pip install -r requirements.txt`, which ships beside it). Ask the gem for
the file's installed location rather than hardcoding a path, and read the
Solver section below first: numpy is not optional there, and the default
parameters cost real time and memory to solve.

## Why Equihash is the shipped default

|  | Argon2id | Cuckatoo29 | **Equihash (default)** |
|---|---|---|---|
| Verify memory | 64 MiB ⚠️ | ~KB | **~KB** |
| Verify time | ~ms (1 Argon2id) | 42 SipHash + walk (unbenched) | **~22 ms valid / 0.3 ms wrong (Ruby)** |
| Lever (solve/verify) | tens× | unbenched | **~440×** (9.6 s / 22 ms) |
| Dependencies | argon2 gem (C-ext) | Pure Ruby | **Pure Ruby (kiosk-pow only)** |
| Difficulty tuning | D=0..256 (smooth) | edgebits | **N×PoW (discrete)** |

**The lever is measured, not asserted.** `~440×` is this README's own two
numbers divided: the p50 reference-solver solve at the shipped n=168 k=7
(~9.6 s, *Performance* below) over a valid proof's verify (~22 ms, *Verify* above);
p95 solve gives ~470×. With YJIT (~15 ms verify) the p50 lever is ~640×. It is a cross-language ratio — a numpy solver against a
pure-Ruby verifier — so read it as the order of magnitude a provider actually
buys, and note that it moves the WRONG way with a faster solver and the right way
with a native verifier. It is not millions at any tuning in the tables below
(192/7, at ~155 s of solve, gives ~7000×), and the number matters
because the lever IS the economic argument for a metered toll — a price on
abuse, not a hardware wall. Cuckatoo29's column says `unbenched` for the same
reason its verify row does: no measurement of it exists here.

The one property that actually matters for a gateway is **cheap verify**:

- **Asymmetric verify.** A few KB (and ~22 ms, pure Ruby — far less for a
  wrong proof, see below) to check — the
  memory footprint is the point: Argon2id needs 64 MiB to _verify_, so a flood
  of bad proofs is a DoS on the verifier itself — unacceptable for a
  high-throughput endpoint.
- **No native code.** Pure Ruby BLAKE2b-256 from `kiosk-pow`. Argon2id needs a C extension.
- **Progressive difficulty via N×PoW.** Instead of a continuous dial the policy
  asks for _N independent proofs_: "1 normally, 10 if you're scraping." Prices
  throughput, not latency (a solver with enough memory runs them in parallel).

No hardware-parity claim is made — none of Argon2id, Cuckatoo, or Equihash
delivers it. Equihash wins on verify cost + no native code, which is what a
provider's own machine pays on every request.

## Parameters

Default: **n=168, k=7** — benchmark-chosen (see [bench/](bench/README.md)):
the largest params whose reference numpy solve stays under a ~30 s / 1–2 GiB
consumer-laptop budget (p95 ~10 s on one M-series laptop core — the only
hardware the seconds have ever been measured on; the ~1.3 GiB peak is THIS
solver's sorted-nonce table, not the host's — and not a floor `(n, k)`
imposes on every implementation, since a memory-optimised solver trades the
table for time, which is precisely how Equihash 200/9's real footprint fell
to ~144 MB and made it ASIC-able). Cost is driven by `n_div = n/(k+1)`.

| Param | **n=168, k=7 (default)** | n=192, k=7 | Zcash (n=200, k=9) | Toy (n=24, k=3) |
|---|---|---|---|---|
| n_div = n/(k+1) | **21** | 24 | 20 | 6 |
| Nonces generated | **2^22 ≈ 4.2M** | 2^25 ≈ 33.5M | 2^21 ≈ 2M | 2^7 = 128 |
| Nonces in proof | **2^7 = 128** | 128 | 2^9 = 512 | 2^3 = 8 |
| Reference solve (numpy, one M-series laptop core) | **~10 s, ~1.3 GiB** | ~155 s, ~5.4 GiB | — | instant |
| Verify cost | **128 BLAKE2b** | 128 BLAKE2b | 512 BLAKE2b | 8 BLAKE2b |

192/7 measures ~155 s and ~5.4 GiB on the reference numpy
solver — too heavy for a laptop, which is why 168/7 is the default. Providers
pick their own `(n, k)` and proof count for their own cost/latency trade-off.

## Memory reuse across parallel challenges

**Buffer reuse: yes. Work reuse: no.**

The solver allocates one sorted-nonce-table buffer (~1.3 GiB at the default
params). This buffer can be reused across challenges (same allocation, different
data). However, the _computational work_ cannot be reused:

- Each challenge has a unique `salt` (raw random bytes, minted by the
  challenge issuer — `kiosk-reputation` mints 16, see its README)
- The seed = `salt ‖ LE32(header_nonce)` is hashed with each nonce
- Different salt → completely different BLAKE2b-256 outputs
- The sorted nonce table must be rebuilt from scratch

This is a deliberate design property: honest clients doing occasional PoWs pay the allocation cost once (buffer reuse). Attackers doing many parallel PoWs must do the full computational work for each — no amortization.

## Anti-abuse strategy: N×PoW

Equihash has discrete difficulty — only via (n, k) parameter changes. Instead of a continuous difficulty dial, the protocol uses **proof count**. A policy picks the count for each client, for example:

```
Normal client:   solve 1 PoW   (1× memory, 1× work)
Suspicious:      solve 3 PoWs   (3× work; parallel if RAM allows)
Abuser:          solve 10 PoWs  (10× work)
```

N prices _throughput_, not latency: a solver with enough memory runs the N
independent proofs in parallel, so wall-clock need not grow 10× — but the total
compute/energy does, which is the cost that lands on a sustained scraper.

This is superior to Argon2id's `D` parameter because:

1. **No verifier changes.** Same `verify()` call, just N times.
2. **Self-documenting.** "You need 10 proofs" tells the client exactly how throttled they are.
3. **Operator-friendly.** Adjust N per-client based on abuse score, no parameter tuning.
4. **Predictable cost.** Each proof is independent — the solver knows exactly how much work is needed.

## Format

Challenge (as issued by the gate — `Kiosk::Reputation::Challenge.issue`):
```json
{
  "id":     "<opaque id>",
  "alg":    "equihash",
  "params": { "n": 168, "k": 7 },
  "salt":   "<base64 salt>",
  "exp":    1751846400,
  "sig":    "<HMAC-SHA256 hex>"
}
```

Proof:
```json
{
  "indices": [128 u64 integers in Zcash-canonical tree order],
  "header_nonce": 0
}
```

The solver accepts the salt under either key — the gate/challenge protocol key
`salt` or the alias `salt_b64`. `header_nonce` is a solver-chosen field of the
*proof*, not a challenge field.

`indices` are **not** globally sorted — they are in canonical Wagner-tree
order (see "Verification contract" below).

## Verification (Ruby)

```ruby
Kiosk::Pow::Equihash.verify(
  salt:   raw_bytes,
  params: { n: 168, k: 7 },
  nonce:  { indices: [/* 128 u64 */] }
)
# => true / false
```

Checks performed (in order):
1. Exactly 2^k distinct non-negative indices below 2^64 (no floats)
2. Collision tree — at each level j, every group of 2^(j+1) leaves:
   - is in **canonical order**: the left half's first index < the right half's, and
   - has its **XOR cancel** the top (j+1)×n_div bits (Wagner cancellation)
3. Global XOR of all 2^k leaf hashes = 0 on n bits

Verification cost: **~22 ms for a valid proof** (128 BLAKE2b-256 hashes, pure
Ruby; measured median at n=168 k=7 on one Apple M3 core, Ruby 4.0.1). Live
memory stays under 3 KB: 1.8 KB at most inside one hash, 0.8 KB between hashes.
The hashes allocate ~16 MB of short-lived objects, and the GC frees them.
With YJIT, which a Rails app enables, it is ~15 ms. A native verifier would be
sub-millisecond. Verify scales with 2^k, not with n: at n=96 k=5 a valid proof
costs ~5.6 ms (32 hashes, same machine) — cheaper to verify, but cheaper to
solve by far more.

**A wrong proof costs far less, deliberately.** The list above is also the
evaluation ORDER, cheapest first, and the leaf hashes are computed one at a
time as the tree folds — so verification stops at the first tree node that does
not cancel. Rubbish indices are rejected without a single hash (0.012 ms
measured); rubbish that is at least well-ordered stops after two hashes
(0.30 ms), against ~22 ms for a complete one. That gap is the point, because
`verify` is reachable unauthenticated on `POST /kiosk/oauth/register`: an attacker who
wants the whole hash loop has to hand over an almost-complete solution, against
a salt that is fresh per challenge.

### Verification contract (why it is XOR-cancellation, not prefix-equality)

Equihash is a *generalized-birthday* PoW: a valid solution is a binary tree of
2^k leaf hashes where **sibling XORs cancel** one n_div-bit block per level.
The leaves in a group do **not** share a common prefix — only their XOR is
zero on that block. Two consequences the verifier must respect:

- **Tree check = XOR, not equality.** Checking "all 2^(j+1) leaves share the
  top (j+1)×n_div bits" is wrong for groups larger than 2 (it is satisfiable
  only by an astronomically rare all-equal cluster — at n=168,k=7 it asks 128
  leaves to share 147 bits, expected count ≈ 2^22/2^147 ≈ 0). The correct
  check is that the group's **XOR** cancels those bits.
- **Order = canonical, not a global sort.** A real solution's tree order is
  not ascending (pair (a,b)+(c,d) may interleave when flattened). Requiring a
  global sort rejects every genuine k≥2 solution. We use Zcash "algorithm
  binding": at each node the left subtree's first index precedes the right's.

## Solver (Python + numpy)

**Verifying is the operator's Ruby; solving is the caller's problem.** Nothing
an operator's server loads to serve a request ever executes a subprocess — the
`verify` above is pure Ruby with no shell-out anywhere in its reach, and
`solve.py` is here for the CALLER that solves the toll, run by the caller's own
process. No process-spawning construct — `Open3`, `system`, backticks,
`IO.popen`, `spawn`, `exec`, `%x` — is reachable from the served set, and no
served file names the solver. The example below is what a CLIENT does, and that is why it is safe.

```bash
pip install numpy          # REQUIRED — see performance note below
python3 solve.py '{"salt_b64":"...", "params":{"n":168,"k":7}}'
# => {"indices": [...128 u64 in canonical tree order...], "header_nonce": 0}
```

`solve.py` ships inside the gem package. From Ruby, a client solves through it
with one call; it raises `SolverError` when the solver refuses:

```ruby
require "kiosk/pow/equihash/solver"
Kiosk::Pow::Equihash.solve(challenge)
# => {"indices" => [...], "header_nonce" => 0}
```

The solver runs full Wagner's algorithm (all pairs within each collision
bucket, not greedy adjacent pairs) and emits the solution in Zcash-canonical
tree order. Every hot step is vectorised in numpy: leaf hashes are packed into
a uint64 array, each level sorts by the n_div-bit collision block, and
collisions/XORs run as whole-array ops. Deep Wagner levels grow degenerate
"megabuckets" of index-reusing entries; the solver caps bucket participation
(`BUCKET_CAP`) to keep work and memory bounded — the real solution comes from
the healthy small buckets, and unsolved seeds retry with the next
`header_nonce`.

**Performance (measured, reference numpy solver, one M-series laptop core):**

| params | p50 solve | p95 solve | peak RSS |
|---|---|---|---|
| n=96, k=5 | ~0.2 s | ~0.3 s | ~44 MiB |
| **n=168, k=7 (default)** | ~9.6 s | ~10.3 s | ~1.3 GiB |
| n=192, k=7 | ~155 s | ~155 s | ~5.4 GiB |

Full grid in [bench/README.md](bench/README.md). This is a REFERENCE
implementation — correct and dependency-light, not a miner. **numpy is not
optional**: the Wagner sort/collide steps are vectorised, and without numpy
`solve.py` refuses to run (exit 3). These numbers are the honest-client
*floor* (slowest participant): a native or GPU solver is faster, since Equihash
parallelises well — which is exactly why the security story is verify-asymmetry
+ reputation, not hardware parity. A provider that needs faster
honest solves lowers `n`; the Ruby verifier stays ~22 ms either way.

See `solve.py` for the implementation.

## Algorithm

Equihash (Biryukov & Khovratovich, 2016). Birthday-collision proof-of-work.

1. Generate 2^(n/(k+1) + 1) nonces
2. For each nonce `i`: `hash_i = BLAKE2b-256(salt ‖ header_nonce ‖ LE64(i))[:n/8]`
3. Wagner's algorithm: k levels of collision search
   - Level j: group entries by top (j+1)×n_div bits, pair within groups
   - Each pair's XOR zeroes those bits
4. Solution: 2^k nonces where XOR of all hashes = 0 on n bits AND the collision tree is valid

## License

Apache-2.0. See `LICENSE.txt`.
