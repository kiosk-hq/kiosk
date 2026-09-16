# Changelog

**Keep the entries short, always under 200 characters and one-two sentences.
Only keep the essence of the change. git commit messages will keep the details.
In the CHANGELOG, only keep the essence.** (Phil, 2026-09-11.) The rule binds
every `CHANGELOG.md` in this repository; `bin/check-changelog` holds it on
entries that are new against its declared baseline commit, and never on the
entries already below.

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The gemspec stops saying the `rake parity` check is «included» and «enforced»: the Rakefile is not packaged and nothing runs the task.
- The gemspec stops claiming kiosk-reputation uses this backend; a host must register it, and nothing here does outside kiosk-server's specs.
- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.

### Added

- `Kiosk::Pow::NAME = "argon2id"` — algorithm name for challenge wire format.
- `Kiosk::Pow.params(d:, m: 65_536, t: 1, p: 1)` — build challenge params for a difficulty tier.
- `Kiosk::Pow.digest(salt:, params:, nonce:)` — one raw Argon2id eval (32 bytes).  Calls `Argon2::Ext.argon2id_hash_raw` directly (bypasses the high-level `m_cost` exponent API) for exact KiB control and version-0x13 determinism.
- `Kiosk::Pow.verify(salt:, params:, nonce:)` — one eval + leading-zero-bits check; exactly one Argon2id evaluation, no loop.
- `Kiosk::Pow.leading_zero_bits(bytes)` — counts leading zero bits spanning bytes; a nonce is valid iff this count over its digest is >= `params[:d]`.
- `solve.py` — Python client solver (argon2-cffi); reads challenge JSON from arg/stdin, loops nonces, prints `{"nonce": "<n>"}`.  Runnable in an assistant sandbox.
- `requirements.txt` — `argon2-cffi` (the only Python dependency).
- `Rakefile` `parity` task — cross-implementation parity proof: Ruby digest == Python digest (hex-equal) for fixed inputs; end-to-end: `solve.py` nonce accepted by Ruby `verify`.
- RSpec suite: `leading_zero_bits` on known byte patterns; `params` shape; `verify` true/false for found/wrong nonce; known-answer determinism vector; `parity`-tagged specs that shell out to Python.
