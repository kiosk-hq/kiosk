# Changelog

**Keep the entries short, always under 200 characters and one-two sentences.
Only keep the essence of the change. git commit messages will keep the details.
In the CHANGELOG, only keep the essence.** (Phil, 2026-09-11.) The rule binds
every `CHANGELOG.md` in this repository; `bin/check-changelog` holds it on
entries that are new against its declared baseline commit, and never on the
entries already below.

- 2026-08-04: new anonymizing KYC broker demo — a standalone issuer
  (not a Kiosk operator; mounts none of the four verbs) that generalizes
  skooti's per-operator KYC stub into a shared broker. It takes an operator
  intake (requested anonymized claims + callback + subject), shows a human a
  no-sign-in yes/no page, and on approval mints a signed, anonymized, single-use
  claim bound to (subject + operator + request) and posts it to the operator's
  allow-listed callback — so an operator gates a regulated action learning only
  booleans and never integrating a government identity service itself. The demo
  self-asserts (a labelled stub); the security model (per-request binding, no
  replay, anti-mass-confirm, SSRF guard) is the point.

- 2026-08-13: closed a TOCTOU race in the human approve action: two
  concurrent approvals of the same pending request used to both pass the
  in-memory single-use check and both mint + deliver a signed claim before
  either write landed. The decision is now an atomic conditional UPDATE
  (`WHERE status = "pending"`) that only the first racer wins; minting only
  ever happens after that claim succeeds, so the "single-use" guarantee the
  schema already documented is now actually enforced under concurrency.
