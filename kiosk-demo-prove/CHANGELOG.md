# Changelog

Significant changes only (CLAUDE.md rule 5): one line per change, 1–2
sentences — essence and intent, not content.

- 2026-08-04: new `prove.my` anonymizing KYC broker demo — a standalone issuer
  (not a Kiosk operator; mounts none of the four verbs) that generalizes
  skooti's per-operator KYC stub into a shared broker. It takes an operator
  intake (requested anonymized claims + callback + subject), shows a human a
  no-sign-in yes/no page, and on approval mints a signed, anonymized, single-use
  claim bound to (subject + operator + request) and posts it to the operator's
  allow-listed callback — so an operator gates a regulated action learning only
  booleans and never integrating a government identity service itself. The demo
  self-asserts (a labelled stub); the security model (per-request binding, no
  replay, anti-mass-confirm, SSRF guard) is the point.
