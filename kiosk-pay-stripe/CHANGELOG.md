# Changelog

## [Unreleased]
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
