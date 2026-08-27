# Equihash parameter benchmark

`bench.py` sweeps a grid of `(n, k)`, runs the reference numpy solver
(`../solve.py`) several times per point, and reports p50/p95 wall-clock solve
time and peak RSS. It picks the shipped default: the largest params whose p95
solve stays under a consumer-laptop budget of **~30 s and 1–2 GiB**.

Cost is driven by `n_div = n/(k+1)` (pool size `N = 2^(n_div+1)`); `n` must be a
multiple of 8 and the solver assumes `n_div ≤ 24`.

Run it yourself:

```
python3 bench/bench.py --markdown            # default grid, 5 samples/point
python3 bench/bench.py --grid 168,7 --samples 5
```

## Measured grid (Apple M-series laptop, numpy 2.5, k=7)

| n | k | n_div | ok/N | p50 s | p95 s | peak MB | note |
|---|---|-------|------|-------|-------|---------|------|
| 144 | 7 | 18 | 2/2 | 0.8 | 0.8 | 334 | too cheap |
| 160 | 7 | 20 | 5/5 | 3.8 | 4.1 | 863 | in budget |
| **168** | **7** | **21** | **5/5** | **9.6** | **10.3** | **1350** | **shipped default** |
| 176 | 7 | 22 | 5/5 | 24.5 | 25.1 | 2424 | time ok, RAM > 2 GiB |
| 184 | 7 | 23 | — | ~60 | ~64 | ~3400 | over budget (1 OOM at 3.5 GB cap) |
| 192 | 7 | 24 | 1/1 | 154.8 | 154.8 | 5377 | prior default — far over budget |

**Chosen: n=168, k=7** — the largest params fully inside the ≤30 s / 1–2 GiB
budget (p95 ~10 s on the Apple M-series laptop the grid above names, ~1.3 GiB).
176/7 keeps the time but breaches the 2 GiB memory
ceiling; 192/7 (the old default) is ~155 s and ~5.4 GiB — unusable on a laptop.

## Caveats (be honest about what this is)

- This is a **reference** solver (pure Python + numpy), not a tuned miner. A
  native or GPU solver is faster — Equihash parallelises well.
  The numbers above are the *honest-client floor*, i.e. the slowest participant.
- The tool is deliberately coarse: a provider picks its own `(n, k)` and proof
  count for its own cost/latency trade-off. These defaults are a sane starting
  point, not a security guarantee. PoW here is a metered toll with a cheap
  verify, not a hardware equaliser — abuse resistance comes from reputation and
  caps.
- Numbers are hardware-specific; re-run `bench.py` on your target to retune.
