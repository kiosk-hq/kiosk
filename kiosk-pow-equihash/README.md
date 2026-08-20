# Kiosk::Pow::Equihash

Memory-hard proof-of-work for Kiosk. Default PoW backend.

Its job is a **cheap-to-verify metered toll**, not a hardware equaliser.
Equihash is not ASIC- or GPU-proof — it was ASIC'd on Zcash (Antminer Z9/Z15)
and GPUs solve it well (the Wagner sort/collide parallelises, and it is
memory-bandwidth-bound). What it buys the provider is a few-KB, ~18 ms
`verify` against a solve that costs the client real time and memory, plus an
`N×PoW` count knob. Abuse resistance comes from reputation and caps
(PoW = metered pricing, not a hardware wall).

## Why Equihash is the shipped default

|  | Argon2id | Cuckatoo29 | **Equihash (default)** |
|---|---|---|---|
| Verify memory | 64 MiB ⚠️ | ~KB | **~KB** |
| Verify time | ~ms (1 Argon2id) | 42 SipHash + walk (unbenched) | **~18 ms valid / 0.3 ms wrong (Ruby)** |
| Lever (solve/verify) | tens× | millions× | **millions×** |
| Dependencies | argon2 gem (C-ext) | Pure Ruby | **Pure Ruby (0 deps)** |
| Difficulty tuning | D=0..256 (smooth) | edgebits | **N×PoW (discrete)** |

The one property that actually matters for a gateway is **cheap verify**:

- **Asymmetric verify.** A few KB (and ~18 ms, pure Ruby — far less for a
  wrong proof, see below) to check — the
  memory footprint is the point: Argon2id needs 64 MiB to _verify_, so a flood
  of bad proofs is a DoS on the verifier itself — unacceptable for a
  high-throughput endpoint.
- **Zero dependencies.** Pure Ruby BLAKE2b-256. Argon2id needs a C extension.
- **Progressive difficulty via N×PoW.** Instead of a continuous dial the policy
  asks for _N independent proofs_: "1 normally, 10 if you're scraping." Prices
  throughput, not latency (a solver with enough memory runs them in parallel).

No hardware-parity claim is made — none of Argon2id, Cuckatoo, or Equihash
delivers it. Equihash wins on verify cost + zero deps, which is what a
provider's own machine pays on every request.

## Parameters

Default: **n=168, k=7** — benchmark-chosen (see [bench/](bench/README.md)):
the largest params whose reference numpy solve stays under a ~30 s / 1–2 GiB
consumer-laptop budget (p95 ~10 s, ~1.3 GiB peak). Cost is driven by
`n_div = n/(k+1)`.

| Param | **n=168, k=7 (default)** | old n=192, k=7 | Zcash (n=200, k=9) | Toy (n=24, k=3) |
|---|---|---|---|---|
| n_div = n/(k+1) | **21** | 24 | 20 | 6 |
| Nonces generated | **2^22 ≈ 4.2M** | 2^25 ≈ 33.5M | 2^21 ≈ 2M | 2^7 = 128 |
| Nonces in proof | **2^7 = 128** | 128 | 2^9 = 512 | 2^3 = 8 |
| Reference solve (numpy) | **~10 s, ~1.3 GiB** | ~155 s, ~5.4 GiB | — | instant |
| Verify cost | **128 BLAKE2b** | 128 BLAKE2b | 512 BLAKE2b | 8 BLAKE2b |

192/7 (the previous default) measured ~155 s and ~5.4 GiB on the reference
numpy solver — too heavy for a laptop; 168/7 is the retuned default. Providers
pick their own `(n, k)` and proof count for their own cost/latency trade-off.

## Memory reuse across parallel challenges

**Buffer reuse: yes. Work reuse: no.**

The solver allocates one sorted-nonce-table buffer (~1.3 GiB at the default
params). This buffer can be reused across challenges (same allocation, different
data). However, the _computational work_ cannot be reused:

- Each challenge has a unique `salt` (random 32 bytes)
- The seed = `salt ‖ LE32(header_nonce)` is hashed with each nonce
- Different salt → completely different BLAKE2b-256 outputs
- The sorted nonce table must be rebuilt from scratch

This is a deliberate design property: honest clients doing occasional PoWs pay the allocation cost once (buffer reuse). Attackers doing many parallel PoWs must do the full computational work for each — no amortization.

## Anti-abuse strategy: N×PoW

Equihash has discrete difficulty — only via (n, k) parameter changes. Instead of a continuous difficulty dial, the protocol uses **proof count**:

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

## Wire format

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

The solver accepts the salt under either key — the gate/challenge wire key
`salt` or the alias `salt_b64`. `header_nonce` is a solver-chosen field of the
*proof*, not a wire-challenge field.

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

Verification cost: **~18 ms for a valid proof** (128 BLAKE2b-256 hashes, pure
Ruby, a few KB; measured median at n=168 k=7). A native verifier would be
sub-millisecond.

**A wrong proof costs far less, deliberately.** The list above is also the
evaluation ORDER, cheapest first, and the leaf hashes are computed one at a
time as the tree folds — so verification stops at the first tree node that does
not cancel. Rubbish indices are rejected without a single hash (0.012 ms
measured); rubbish that is at least well-ordered stops after two hashes
(0.30 ms). Every one of those used to cost the full 18.7 ms, which mattered
because `verify` is reachable unauthenticated on `POST /auth/register`: an
attacker who wants the whole hash loop must now hand over an almost-complete
solution, against a salt that is fresh per challenge.

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

> **History.** Before this fix the verifier checked leaf-prefix *equality* plus
> a global ascending sort. Both are invisible at k=1 (one pair: tree order ==
> sorted, and XOR-cancel == equal), which is all the KATs and demos exercised —
> so the bug was latent, and equihash never accepted a real proof at the
> production parameters (k=7). Fixed to the Zcash-canonical contract above;
> `spec/kiosk/pow/equihash_spec.rb` now carries k=2 and k=3 KATs.

## Solver (Python + numpy)

```bash
pip install numpy          # REQUIRED — see performance note below
python3 solve.py '{"salt_b64":"...", "params":{"n":168,"k":7}}'
# => {"indices": [...128 u64 in canonical tree order...], "header_nonce": 0}
```

`solve.py` ships inside the gem package. From Ruby, ask the gem for its
installed location instead of hardcoding a path — this is the public accessor
consumers shell out to (the `kiosk-redteam` client uses it):

```ruby
Kiosk::Pow::Equihash.solver_path
# => "/.../gems/kiosk-pow-equihash-0.3.0/solve.py"
Open3.capture2("python3", Kiosk::Pow::Equihash.solver_path, challenge_json)
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
| **n=168, k=7 (default)** | ~9.6 s | ~10.3 s | ~1.3 GiB |
| n=192, k=7 (old default) | ~155 s | ~155 s | ~5.4 GiB |

Full grid in [bench/README.md](bench/README.md). This is a REFERENCE
implementation — correct and dependency-light, not a miner. **numpy is not
optional** — the Wagner sort/collide steps are vectorised; without it the pure
Python path is an order of magnitude slower. These numbers are the honest-client
*floor* (slowest participant): a native or GPU solver is faster, since Equihash
parallelises well — which is exactly why the security story is verify-asymmetry
+ reputation, not hardware parity. A provider that needs faster
honest solves lowers `n`; the Ruby verifier stays ~18 ms either way.

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
