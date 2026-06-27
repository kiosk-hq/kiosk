# kiosk-pow-cuckoo — SKILL fragment

## What this gem provides

### The VERIFIER — production-correct
`Kiosk::Pow::Cuckoo.verify(salt:, params:, nonce:)` is production-correct and
validated against Grin's Cuckatoo29 L=42 known-answer test vector.  35 specs
green.  Pure Ruby, clean-room, no GPL code, Apache-2.0.

Verification cost: `proofsize` SipHash-2-4 evaluations + cycle-walk ≈ 10 μs.
The large solve:verify asymmetry is the point: solving costs GB-RAM × seconds;
verifying costs microseconds.

### The SOLVER — reference/toy only
`solve_cuckoo.py` is a **pure-Python + numpy REFERENCE solver for small edgebits
and reduced proofsize only**.  It is NOT capable of solving production Cuckatoo
(L=42, edgebits≥29).  It is included for mechanism demonstration.

**Cannot solve production sizes.** Pure Python cannot handle the GB+ allocations
or the search time required at edgebits≥29.

## Wire interface deviation

Unlike `kiosk-pow` (Argon2id), the Cuckatoo proof is **composite**:

```json
{ "header_nonce": 1, "cycle": [12, 362, 383, 633, 694, 717, 849, 872, 934, 944, 948, 961] }
```

`kiosk-reputation` passes this composite object unchanged — it does not assume
nonce is a String.  The backend's `.verify` receives the full Hash.

## Toy mechanism demo

**TOY MECHANISM DEMO — proofsize 12 at edgebits 10; NOT production difficulty.**

```bash
cd oss/kiosk-dem-foodelivery
bundle exec rake demo:cuckoo
```

Demonstrates the 402 → Cuckatoo solve → 200 loop and wrong-proof → 403.

## Production deployment notes

1. **Provider mandates the algorithm** (ADR-0001). Clients that cannot solve
   are denied — intentional.
2. **Argon2id (`kiosk-pow`) is the practical default** with a uniformly-fast
   solver on all platforms. Choose Cuckatoo specifically for the extreme
   solve:verify asymmetry.
3. **Production solver**: requires a native C/CUDA miner (Tromp's lean/mean
   or similar). The Python solver is for demonstration only.
4. **Proofsize**: production is L=42 (Grin/Tromp standard). The toy demo uses
   L=12 to fit in ~1 second on the reference Python solver.
5. **ASIC note**: Cuckatoo is NOT ASIC-proof. 1 GB-SRAM ASICs exist for
   edgebits=31+. The provider raises the bar for abusers; ASIC clients solve
   faster, not cheaper.
