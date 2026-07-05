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
  "indices": [128 ascending u64 integers],
  "header_nonce": 0
}
```

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
1. Exactly 2^k indices, strictly ascending, no floats
2. Global XOR of all 2^k hashes = 0 on n bits
3. Collision tree: at level j, groups of 2^(j+1) indices share top (j+1)×n_div bits

Verification cost: 128 BLAKE2b-256 hashes → ~microseconds.

## Solver (Python)

```bash
python3 solve.py '{"salt_b64":"...", "params":{"n":192,"k":7}}'
# => {"indices": [...128 u64...], "header_nonce": 0}
```

The solver uses Wagner's algorithm with greedy adjacent pairing. It retries with incrementing `header_nonce` until a valid solution (passing collision-tree verification) is found. For production parameters (n=192, k=7), solutions are typically found within a few attempts.

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
