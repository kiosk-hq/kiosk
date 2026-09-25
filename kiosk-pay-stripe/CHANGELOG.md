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
- **The rubygems blurb stopped forecasting PSP adapters that do not exist (K-1673).** It names the base class a host subclasses instead.
- **The rubygems blurb credited this gem's charging to a `kiosk-core` method that only raises (K-1688).** It names this adapter's own `#capture` now.
- **`return_url:` — the keyword whose absence raises — is documented, and three stale or inverted comments are gone (K-1690, K-1691, K-1692).**
- The two operator log lines that report a degraded `setup_url` now end in the
  condition itself rather than in an internal tracker id nobody outside this
  project can look up.
- A failed lookup for the outstanding setup session is now logged instead of
  passing for "there is none": the adapter still degrades to minting a fresh
  session so the readiness probe keeps answering, but it says so, because the
  degrade is otherwise byte-for-byte identical to the stable-url happy path.
- `setup_url` is now stable across calls (K-492): it reuses the `mode:setup`
  Checkout Session already outstanding for the customer instead of creating a
  new one per call, so a host polling card-setup readiness keeps handing its
  human the same link.
- Initial Stripe PSP adapter (test mode): SetupIntent card-on-file with
  off_session capture (`customer_resolver`/`customer_saver`, `setup_url`,
  `setup_required?`, `saved_method?`), plus a `pm_card_visa` back-compat
  fallback and a `test_autocard`/`attach_test_card` path for automated suites.
