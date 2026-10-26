# Changelog

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

- 2026-10-26: The gem is `kiosk-kyc-proveli` and the class `Kiosk::KycProviders::Proveli`. The broker serves its public key at `/proveli_key.pem`.

## [0.6.26] — 2026-10-26

- 2026-10-26: Version 0.6.26, the tree cut that matches skill 0.6.26.
## [0.6.25] — 2026-10-26

- 2026-10-26: Version 0.6.25, the tree cut that matches skill 0.6.25.
- 2026-10-26: The README says the hosted broker serves only the demo operators, and how an operator runs its own broker and configures the adapter for it.

## [0.6.24] — 2026-10-26

- 2026-10-26: Version 0.6.24, the tree cut that matches skill 0.6.24.

## [0.6.23] — 2026-10-26

- 2026-10-26: Version 0.6.23, the tree cut that matches skill 0.6.23.

## [0.6.22] — 2026-10-26

- 2026-10-26: Version 0.6.22, the tree cut that matches skill 0.6.22.

## [0.6.21] — 2026-10-26

- 2026-10-26: Version 0.6.21, the tree cut that matches skill 0.6.21.

## [0.6.20] — 2026-10-26

- 2026-10-26: Version 0.6.20, the tree cut that matches skill 0.6.20.

## [0.6.19] — 2026-10-26

- 2026-10-26: Version 0.6.19, the tree cut that matches skill 0.6.19.

## [0.6.18] — 2026-10-25

- 2026-10-25: Version 0.6.18, the tree cut that matches skill 0.6.18.

## [0.6.17] — 2026-10-25

- 2026-10-25: Version 0.6.17, the tree cut that matches skill 0.6.17.

## [0.6.16] — 2026-10-25

- 2026-10-25: Version 0.6.16, the tree cut that matches skill 0.6.16.

## [0.6.15] — 2026-10-25

- 2026-10-25: Version 0.6.15, the tree cut that matches skill 0.6.15.

## [0.6.14] — 2026-10-25

- 2026-10-25: Version 0.6.14, the tree cut that matches skill 0.6.14.

## [0.6.13] — 2026-10-25

- 2026-10-25: Version 0.6.13, the tree cut that matches skill 0.6.13.

## [0.6.12] — 2026-10-24

- 2026-10-24: Version 0.6.12, the tree cut that matches skill 0.6.12.

- 2026-10-24: `Prove.new` takes the broker's `public_key:` and optional `issuer:`; the operator id is the audience.

## [0.6.11] — 2026-10-24

- 2026-10-24: Version 0.6.11, the tree cut that matches skill 0.6.11.

## [0.6.10] — 2026-10-23

- 2026-10-23: Version 0.6.10, the tree cut that matches skill 0.6.10.

## [0.6.9] — 2026-10-23

- 2026-10-23: Version 0.6.9, the tree cut that matches skill 0.6.9.

## [0.6.8] — 2026-10-22

- 2026-10-22: Version 0.6.8, the tree cut that matches skill 0.6.8.

## [0.6.7] — 2026-10-22

- 2026-10-22: Version 0.6.7, the tree cut that matches skill 0.6.7.

## [0.6.6] — 2026-10-22

- 2026-10-22: Version 0.6.6, the tree cut that matches skill 0.6.6.

## [0.6.5] — 2026-10-22

- 2026-10-22: Version 0.6.5, the tree cut that matches skill 0.6.5.

## [0.6.4] — 2026-10-22

- 2026-10-22: Version 0.6.4, the tree cut that matches skill 0.6.4.

## [0.6.3] — 2026-10-22

- 2026-10-22: Version 0.6.3, the tree cut that matches skill 0.6.3.

## [0.6.2] — 2026-10-22

- 2026-10-22: Version 0.6.2, the tree cut that matches skill 0.6.2.

## [0.6.1] — 2026-10-22

- 2026-10-22: Version 0.6.1, the tree cut that matches skill 0.6.1.

## [0.6.0] — 2026-10-21

- 2026-10-21: Version 0.6.0, the tree cut that matches skill 0.6.0.

## [0.5.27] — 2026-10-21

- 2026-10-21: Version 0.5.27, the tree cut that matches skill 0.5.27.

## [0.5.26] — 2026-10-21

- 2026-10-21: Version 0.5.26, the tree cut that matches skill 0.5.26.

## [0.5.25] — 2026-10-21

- 2026-10-21: Version 0.5.25, the tree cut that matches skill 0.5.25.

## [0.5.24] — 2026-10-21

- 2026-10-21: Version 0.5.24, the tree cut that matches skill 0.5.24.

## [0.5.23] — 2026-10-21

- 2026-10-21: Version 0.5.23, the tree cut that matches skill 0.5.23.

## [0.5.22] — 2026-10-21

- 2026-10-21: Version 0.5.22, the tree cut that matches skill 0.5.22.

## [0.5.21] — 2026-10-21

- 2026-10-21: Version 0.5.21, the tree cut that matches skill 0.5.21.

## [0.5.20] — 2026-10-20

- 2026-10-20: Version 0.5.20, the tree cut that matches skill 0.5.20.

## [0.5.19] — 2026-10-20

- 2026-10-19: The adapter asks the broker for the attribute names in `kyc_claims` as they are. The broker names a licence by its category, such as `licence_a1` or `licence_a`.
- 2026-10-19: The broker client connects to an intake URL that names an IPv6 literal, such as `http://[::1]:3004/`.

## [0.5.18] — 2026-10-18

- 2026-10-18: Version 0.5.18, the tree cut that matches skill 0.5.18.

## [0.5.17] — 2026-10-18

- 2026-10-18: A broker answer that is not HTTP raises `Unavailable`, so `request_kyc` answers `action_failed`, not 500.

## [0.5.16] — 2026-10-18

- 2026-10-18: Version 0.5.16, the tree cut that matches skill 0.5.16.

## [0.5.15] — 2026-10-18

- 2026-10-18: Version 0.5.15, the tree cut that matches skill 0.5.15.

## [0.5.14] — 2026-10-18

- 2026-10-18: Version 0.5.14, the tree cut that matches skill 0.5.14; this gem's surface is unchanged.

## [0.5.13] — 2026-10-11

- 2026-10-11: Version 0.5.13, the tree cut that matches skill 0.5.13.

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
