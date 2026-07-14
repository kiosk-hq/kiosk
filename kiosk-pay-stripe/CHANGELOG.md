# Changelog

## [Unreleased]
- Initial Stripe PSP adapter (test mode): SetupIntent card-on-file with
  off_session capture (`customer_resolver`/`customer_saver`, `setup_url`,
  `setup_required?`, `saved_method?`), plus a `pm_card_visa` back-compat
  fallback and a `test_autocard`/`attach_test_card` path for automated suites.
