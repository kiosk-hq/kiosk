# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Kiosk::Pow::Equihash` — pure-Ruby Equihash (Biryukov & Khovratovich) verifier, the shipped default Kiosk PoW backend. No runtime dependencies: BLAKE2b-256 is clean-room pure Ruby from the public-domain BLAKE2 spec, and the gem depends on neither `kiosk-core` nor Rails.
- `Kiosk::Pow::Equihash::NAME = "equihash"` — algorithm identifier for the challenge wire format.
- `Kiosk::Pow::Equihash.params(n: 168, k: 7)` — challenge params; `DEFAULT_N` / `DEFAULT_K` carry the shipped defaults.
- `Kiosk::Pow::Equihash.verify(salt:, params:, nonce:)` — recomputes the `2^k` BLAKE2b-256 leaf hashes named by the proof's indices, checks their XOR is zero over all `n` bits, and walks the Wagner collision tree (per-level XOR cancellation plus the Zcash-canonical subtree ordering). Difficulty is set by `(n, k)` alone — there is no post-hoc target check.
- `Kiosk::Pow::Equihash.blake2b256` — public so specs can check it directly against Python `hashlib.blake2b` vectors.
- `solve.py` — reference Python + numpy solver (a correct full-Wagner implementation, not a tuned miner), with a `--toy` `(n=24, k=3)` mode for tests.
- `Kiosk::Pow::Equihash.solver_path` — public accessor returning the absolute path of the packaged `solve.py`, so consumers (the `kiosk-redteam` client first) shell out to the shipped solver by asking this gem instead of hardcoding a checkout-relative path that breaks in an installed gem.
- `bench/bench.py` and `bench/README.md` — the `(n, k)` sweep behind the default, reporting p50/p95 solve time and peak RSS.
- Known-answer tests frozen at the SHIPPED production parameters (n=168, k=7), not only at toy params — a toy-only KAT is what let a broken verifier pass, and `k=2`/`k=3` vectors now cover the tree check the old one could not see.
- Live solver-to-verifier parity spec at 168/7 — `solve.py` produces a proof and `.verify` accepts it; CI installs numpy so the job actually runs it rather than skipping.
- `spec/solver_pin_spec.rb` — runs `bin/check-solver-pin` from this gem's own suite, so editing `solve.py` fails here rather than silently breaking every assistant that verifies the file's SHA-256 against the pin published in the skill. Skips, stating why, in a gem-only checkout where the script is absent.

### Changed

- **`.verify` now has an ANSWER for degenerate `(n, k)` — `false` — instead of a crash or a vacuous accept (K-840).** A negative `k` collapsed `1 << k` to 0, so an EMPTY indices array satisfied the length check and the root step dereferenced an empty stack (`NoMethodError`); `n = 0` (or any `n` below one byte) made every leaf the integer 0, so ANY `2^k` distinct ascending indices verified TRUE — a proof nobody supplied. `n` is now required to be `8..256` (the width a BLAKE2b-256 leaf can actually carry), `k` non-negative, and `n / (k + 1)` at least one bit per level; anything else is a malformed challenge, not an exception and not a solution. Not reachable over the wire — `Challenge.verify` re-derives the parameters from live config before the backend runs — so this is robustness against operator mis-config. The accepted set is unchanged: `n % (k + 1) == 0` is deliberately NOT required, because the hand-computed `(n=8, k=2)` KAT is a real accepted solution with `8 % 3 == 2`.

- Default parameters retuned from n=192, k=7 to **n=168, k=7** after benchmarking: 192/7 measured ~155 s and ~5.4 GiB on the reference solver, too heavy for a consumer laptop; 168/7 lands at p95 ~10 s and ~1.3 GiB.
- README and docstrings state what the gem actually is — a cheap-to-verify metered toll at ~17 ms and a few KB per verify, priced by the reputation policy's N-proofs knob. The ASIC-/GPU-resistance claims and the microsecond-verify figure are gone: Equihash was ASIC'd on Zcash, and neither claim was supportable.
- `DEFAULT = true` removed — defaultness is established by registry wiring, not by a constant on this module.
- `.verify` now costs a WRONG proof far less than a right one: the index checks (count, type, u64 range, distinctness, canonical subtree ordering) run before any hashing, and the leaf hashes are computed one at a time as the Wagner tree folds, so verification stops at the first node that fails. Measured at n=168 k=7: unordered rubbish 0.012 ms and well-ordered rubbish 0.30 ms, against 18.7 ms when every proof paid the full 128-hash loop; a valid proof is unchanged at ~18 ms. Which proofs verify is unchanged — `verify` is reachable unauthenticated on `POST /auth/register`, so what changes is how much an attacker can buy with a proof they did not solve (K-540).
- An index at or above 2**64 is rejected instead of being truncated by `pack("Q<")`, which had made `idx` and `idx + 2**64` two spellings of one leaf.
- `bench/` and everything under `lib/` ship unconditionally, so the packaged README's links to the benchmark evidence resolve inside the gem. `CHANGELOG.md` is listed the same way: the file list has no `File.exist?` guard, so a file this gemspec names and cannot find breaks the build instead of going quiet.
- The gemspec declares a description, a homepage and the `homepage_uri` / `source_code_uri` / `bug_tracker_uri` / `changelog_uri` metadata, which it had never carried — the default PoW backend used to render on RubyGems as a bare summary line with no prose and no links.

### Fixed

- Verifier rewritten to the Zcash-canonical collision-tree check. The previous one checked leaf-prefix *equality* plus a global ascending sort; both are invisible at k=1, which is all the tests exercised, so it never accepted a real proof at the production parameters.
- `verify` returns `false` instead of raising on a malformed proof — a non-Integer or negative index, a duplicate index, a wrong-length index list, or a non-numeric `header_nonce`.
