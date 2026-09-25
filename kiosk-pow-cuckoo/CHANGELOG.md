# Changelog

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

## [0.5.0] — 2026-09-26

### Changed

- **Three sentences priced the toy solve at «~1 second» with no machine named (K-1698).** The figure is gone; `rake solve_parity` prints its own timing.
- **The packaged solver drops a scalar SipHash and a parameter nothing called, and stops narrating a version that no longer exists (K-1685, K-1686).**
- **Two comments stated a salt length the base64 literal beside them refutes (K-1684).** The numbers are removed rather than corrected.
- **`verify` answers false for seven more malformed-input shapes where it used to raise (K-1683).** Its own comment and the sibling Equihash backend already promised that.
- The gemspec stops labelling itself with private roadmap phases (T1, T2/T3) that nothing an adopter can open resolves.

### Added
- Clean-room Cuckatoo-Cycle verifier
- Pure-Ruby BLAKE2b-256 (from public-domain BLAKE2 spec)
- Pure-Ruby SipHash-2-4 with Cuckatoo non-standard initialization
- Cuckatoo cycle walk verifier
- Optional blake2b-256 difficulty target check
- Validated against Grin's Cuckatoo29 CI known-answer vector (nonce=20)
