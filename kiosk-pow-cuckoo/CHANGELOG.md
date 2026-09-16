# Changelog

**Keep the entries short, always under 200 characters and one-two sentences.
Only keep the essence of the change. git commit messages will keep the details.
In the CHANGELOG, only keep the essence.** (Phil, 2026-09-11.) The rule binds
every `CHANGELOG.md` in this repository; `bin/check-changelog` holds it on
entries that are new against its declared baseline commit, and never on the
entries already below.

## [Unreleased]

### Changed

- **`verify` answers false for seven more malformed-input shapes where it used to raise (K-1683).** Its own comment and the sibling Equihash backend already promised that.
- The gemspec stops labelling itself with private roadmap phases (T1, T2/T3) that nothing an adopter can open resolves.

### Added
- Clean-room Cuckatoo-Cycle verifier
- Pure-Ruby BLAKE2b-256 (from public-domain BLAKE2 spec)
- Pure-Ruby SipHash-2-4 with Cuckatoo non-standard initialization
- Cuckatoo cycle walk verifier
- Optional blake2b-256 difficulty target check
- Validated against Grin's Cuckatoo29 CI known-answer vector (nonce=20)
