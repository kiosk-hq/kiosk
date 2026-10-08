# Changelog

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

- 2026-10-09: **`Prove.issuer` and `Prove.broker_url` are removed**: the gem reads no ENV; pass `url:` and set `c.kyc_issuer` yourself.

## [0.5.12] — 2026-10-08

- 2026-10-08: Version 0.5.12, the tree cut that matches skill 0.5.12; this gem's surface is unchanged.

## [0.5.11] — 2026-10-08

- 2026-10-08: Version 0.5.11, the tree cut that matches skill 0.5.11; this gem's surface is unchanged.

## [0.5.10] — 2026-10-08

- 2026-10-08: Version 0.5.10, the tree cut that matches skill 0.5.10; this gem's surface is unchanged.

## [0.5.9] — 2026-10-08

- 2026-10-08: Version 0.5.9, the tree cut that matches skill 0.5.9; this gem's surface is unchanged.

## [0.5.8] — 2026-10-07

- 2026-10-07: Version 0.5.8, the tree cut that matches skill 0.5.8; this gem's surface is unchanged.

## [0.5.7] — 2026-10-07

- 2026-10-07: Version 0.5.7, the tree cut that matches skill 0.5.7; this gem's surface is unchanged.

## [0.5.6] — 2026-10-07

- 2026-10-07: Version 0.5.6, the tree cut that matches skill 0.5.6; this gem's surface is unchanged.

## [0.5.5] — 2026-10-07

- 2026-10-07: Version 0.5.5, the tree cut that matches skill 0.5.5; this gem's surface is unchanged.

## [0.5.4] — 2026-10-07

- 2026-10-07: **New gem: the Prove KYC broker behind `Kiosk::KycProviders::Base`**, moved out of the getgrocery and skooti demos (T-220).
