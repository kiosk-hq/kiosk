# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Kiosk::Pow::NAME = "argon2id"` — algorithm name for challenge wire format.
- `Kiosk::Pow.params(d:, m: 65_536, t: 1, p: 1)` — build challenge params for a difficulty tier.
- `Kiosk::Pow.digest(salt:, params:, nonce:)` — one raw Argon2id eval (32 bytes).  Calls `Argon2::Ext.argon2id_hash_raw` directly (bypasses the high-level `m_cost` exponent API) for exact KiB control and version-0x13 determinism.
- `Kiosk::Pow.verify(salt:, params:, nonce:)` — one eval + leading-zero-bits check; exactly one Argon2id evaluation, no loop.
- `Kiosk::Pow.leading_zero_bits(bytes)` — counts leading zero bits spanning bytes (matches `Kiosk::Server::ProofOfWork.leading_zero_bits` semantics).
- `solve.py` — Python client solver (argon2-cffi); reads challenge JSON from arg/stdin, loops nonces, prints `{"nonce": "<n>"}`.  Runnable in an assistant sandbox.
- `requirements.txt` — `argon2-cffi` (the only Python dependency).
- `SKILL.md` — shippable skill fragment: how an assistant handles `pow_required`.
- `Rakefile` `parity` task — cross-implementation parity proof: Ruby digest == Python digest (hex-equal) for fixed inputs; end-to-end: `solve.py` nonce accepted by Ruby `verify`.
- RSpec suite: `leading_zero_bits` on known byte patterns; `params` shape; `verify` true/false for found/wrong nonce; known-answer determinism vector; `parity`-tagged specs that shell out to Python.
