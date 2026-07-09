# Kiosk::Pow::Equihash

Memory-hard proof-of-work for Kiosk. Default PoW backend.

## Why Equihash is the default

|  | Argon2id | Cuckatoo29 | **Equihash 192/7** |
|---|---|---|---|
| Solver memory | 64 MiB | ~4 GiB | **~1 GiB** |
| Verify memory | 64 MiB ⚠️ | ~KB | **~KB** |
| Verify time | ~ms (1 Argon2id) | µs (42 edges) | **µs (128 BLAKE2b)** |
| Lever (solve/verify) | tens× | millions× | **millions×** |
| ASIC barrier | L3-cacheable | SRAM for 4G | **HBM/DDR, 1G SRAM ~$1k** |
| Dependencies | argon2 gem (C-ext) | Pure Ruby | **Pure Ruby (0 deps)** |
| Difficulty tuning | D=0..256 (smooth) | edgebits | **N×PoW (discrete)** |

Equihash beats Argon2id on every dimension that matters for an agent-commerce protocol:

- **Asymmetric:** 1 GiB to solve, microseconds to verify. Argon2id requires 64 MiB to _verify_ — unacceptable for a high-throughput gateway.
- **Zero dependencies:** Pure Ruby BLAKE2b-256. Argon2id needs a C extension.
- **ASIC-resistant at 1 GiB:** Custom SRAM for 1 GiB costs ~$1k per chip. GPU/FPGA need HBM/DDR — commodity hardware, no ASIC advantage.
- **Progressive difficulty via N×PoW:** Instead of a continuous difficulty dial (Argon2id's `D=0..256`), the protocol asks for _N independent proofs_. This is simpler, self-documenting, and lets operators tune anti-abuse per-client: "solve 1 PoW normally, 10 if you're spamming."

## Parameters

Default: **n=192, k=7** (~1 GiB solver memory).

| Param | n=192, k=7 | Zcash (n=200, k=9) | Toy (n=24, k=3) |
|---|---|---|---|
| n_div = n/(k+1) | 24 | 20 | 6 |
| Nonces generated | 2^25 ≈ 33.5M | 2^21 ≈ 2M | 2^7 = 128 |
| Nonces in proof | 2^7 = 128 | 2^9 = 512 | 2^3 = 8 |
| Solver RAM | ~1 GiB | ~50 MiB | ~KB |
| Verify cost | 128 BLAKE2b | 512 BLAKE2b | 8 BLAKE2b |

Our parameters are intentionally 20× more memory-intensive than Zcash's, targeting a meaningful ASIC barrier while remaining feasible on high-end mobile devices and laptops.

## Memory reuse across parallel challenges

**Buffer reuse: yes. Work reuse: no.**

The solver allocates ~1 GiB for the sorted nonce table. This buffer can be reused across challenges (same allocation, different data). However, the _computational work_ cannot be reused:

- Each challenge has a unique `salt` (random 32 bytes)
- The seed = `salt ‖ LE32(header_nonce)` is hashed with each nonce
- Different salt → completely different BLAKE2b-256 outputs
- The sorted nonce table must be rebuilt from scratch

This is a deliberate design property: honest clients doing occasional PoWs pay the allocation cost once (buffer reuse). Attackers doing many parallel PoWs must do the full computational work for each — no amortization.

## Anti-abuse strategy: N×PoW

Equihash has discrete difficulty — only via (n, k) parameter changes. Instead of a continuous difficulty dial, the protocol uses **proof count**:

```
Normal client:   solve 1 PoW  (1 GiB, ~seconds)
Suspicious:      solve 3 PoWs (3 GiB, 3× time)
Abuser:          solve 10 PoWs (10 GiB, 10× time)
```

This is superior to Argon2id's `D` parameter because:

1. **No verifier changes.** Same `verify()` call, just N times.
2. **Self-documenting.** "You need 10 proofs" tells the client exactly how throttled they are.
3. **Operator-friendly.** Adjust N per-client based on abuse score, no parameter tuning.
4. **Predictable cost.** Each proof is independent — the solver knows exactly how much work is needed.

## Wire format

Challenge:
```json
{
  "alg": "equihash",
  "salt_b64": "<base64 32 bytes>",
  "params": { "n": 192, "k": 7 },
  "header_nonce": 0
}
```

Proof:
```json
{
  "indices": [128 u64 integers in Zcash-canonical tree order],
  "header_nonce": 0
}
```

`indices` are **not** globally sorted — they are in canonical Wagner-tree
order (see "Verification contract" below).

## Verification (Ruby)

```ruby
Kiosk::Pow::Equihash.verify(
  salt:   raw_bytes,
  params: { n: 192, k: 7 },
  nonce:  { indices: [/* 128 u64 */] }
)
# => true / false
```

Checks performed (in order):
1. Exactly 2^k distinct, non-negative indices (no floats)
2. Global XOR of all 2^k leaf hashes = 0 on n bits
3. Collision tree — at each level j, every group of 2^(j+1) leaves:
   - has its **XOR cancel** the top (j+1)×n_div bits (Wagner cancellation), and
   - is in **canonical order**: the left half's first index < the right half's.

Verification cost: 128 BLAKE2b-256 hashes → ~microseconds.

### Verification contract (why it is XOR-cancellation, not prefix-equality)

Equihash is a *generalized-birthday* PoW: a valid solution is a binary tree of
2^k leaf hashes where **sibling XORs cancel** one n_div-bit block per level.
The leaves in a group do **not** share a common prefix — only their XOR is
zero on that block. Two consequences the verifier must respect:

- **Tree check = XOR, not equality.** Checking "all 2^(j+1) leaves share the
  top (j+1)×n_div bits" is wrong for groups larger than 2 (it is satisfiable
  only by an astronomically rare all-equal cluster — at n=192,k=7 it asks 128
  leaves to share 168 bits, expected count ≈ 2^25/2^168 ≈ 0). The correct
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
python3 solve.py '{"salt_b64":"...", "params":{"n":192,"k":7}}'
# => {"indices": [...128 u64 in canonical tree order...], "header_nonce": 0}
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

**Performance (measured, n=192 k=7, one M-series laptop core):** ~140 s and
~6 GB peak. This is a REFERENCE implementation — correct and dependency-light,
not a miner. The floor is inherent to pure Python + numpy at 2^25 entries: the
BLAKE2b generation alone is ~12 s (stdlib, unvectorisable), and seven collision
rounds over 33.5 M rows dominate the rest. **numpy is not optional** — without
it the pure-Python path is >10× slower (≈90 s → many minutes) and ~5 GB from
Python object overhead. A production agent that needs sub-minute solves should
bind an optimised native solver (e.g. tromp/equihash); the Ruby verifier is
unaffected (µs either way).

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
