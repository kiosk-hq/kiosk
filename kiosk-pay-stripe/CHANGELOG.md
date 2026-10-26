# Changelog

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

- 2026-10-26: The README says the adapter does not check whether the Stripe key is a test-mode key; it names operators and customers.

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
- The principal → Customer mapping is the `kiosk_stripe_customers` table.

## [0.6.15] — 2026-10-25

- 2026-10-25: Version 0.6.15, the tree cut that matches skill 0.6.15.

## [0.6.14] — 2026-10-25

- 2026-10-25: Version 0.6.14, the tree cut that matches skill 0.6.14.

## [0.6.13] — 2026-10-25

- 2026-10-25: Version 0.6.13, the tree cut that matches skill 0.6.13.

## [0.6.12] — 2026-10-24

- 2026-10-24: Version 0.6.12, the tree cut that matches skill 0.6.12.

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

- 2026-10-21: `capture` answers `network_confirmation_id`, the card network's id of the charge from its `latest_charge`, or nil when the network gave none.
- 2026-10-21: Version 0.5.24, the tree cut that matches skill 0.5.24.

## [0.5.23] — 2026-10-21

- 2026-10-21: Version 0.5.23, the tree cut that matches skill 0.5.23.

## [0.5.22] — 2026-10-21

- 2026-10-21: The capture is keyed by the checkout mandate's reference.
- 2026-10-21: Version 0.5.22, the tree cut that matches skill 0.5.22.

## [0.5.21] — 2026-10-21

- 2026-10-21: Version 0.5.21, the tree cut that matches skill 0.5.21.

## [0.5.20] — 2026-10-20

- 2026-10-20: Version 0.5.20, the tree cut that matches skill 0.5.20.

## [0.5.19] — 2026-10-20

- 2026-10-20: Version 0.5.19, the tree cut that matches skill 0.5.19.

## [0.5.18] — 2026-10-18

- 2026-10-18: Version 0.5.18, the tree cut that matches skill 0.5.18.

## [0.5.17] — 2026-10-18

- 2026-10-18: kiosk-pay-stripe keys a capture by the Stripe customer and the cart mandate id, so the carts of two customers cannot share an idempotency key.
- 2026-10-18: `refund` takes `key:`, which names the refund among the refunds of its charge; kiosk-pay-stripe keys the Stripe request by the charge and that key.
- 2026-10-18: `PaymentFailed` takes no `reason:`; the engine reads only its message and `retryable?`.

## [0.5.16] — 2026-10-18

- 2026-10-18: Each adapter has its own Stripe client; `api_base:` names another API URL, e.g. stripe-mock. The adapter no longer sets `Stripe.api_key`.
- 2026-10-18: A saved-card check is one Stripe call: the newest card on the Customer. A `pay` makes three calls, not five.

## [0.5.15] — 2026-10-18

- 2026-10-18: `bin/rails g kiosk:pay_stripe:install` writes the `stripe_customers` migration with its DDL in the file. `CustomerRecord.create_table` is removed.

## [0.5.14] — 2026-10-18

- 2026-10-18: Version 0.5.14, the tree cut that matches skill 0.5.14.

- 2026-10-17: **`test_autocard:` and `attach_test_card` are removed**; a suite saves a card through `payment_setup`, as production does.

- 2026-10-17: `Stripe::ChargeLookup` is removed; nothing an operator runs used it.

## [0.5.13] — 2026-10-11

- 2026-10-11: Version 0.5.13, the tree cut that matches skill 0.5.13.

- 2026-10-09: **`Stripe.new` requires `api_key:`**; the adapter no longer falls back to `STRIPE_SECRET_KEY`.

## [0.5.12] — 2026-10-08

- 2026-10-08: Version 0.5.12, the tree cut that matches skill 0.5.12; this gem's surface is unchanged.

## [0.5.11] — 2026-10-08

- 2026-10-08: Version 0.5.11, the tree cut that matches skill 0.5.11; this gem's surface is unchanged.

## [0.5.10] — 2026-10-08

- 2026-10-08: Version 0.5.10, the tree cut that matches skill 0.5.10 and carries the entries below.

- 2026-10-08: A capture settles only a `succeeded` card PaymentIntent, at what it received; any other status is refused as a decline or an unknown outcome.
- 2026-10-08: A capture settles the confirmed intent's amount, the cart total the spec requires, rather than `amount_received`.
- 2026-10-08: `CustomerRecord` keeps the principal→Customer mapping in a `stripe_customers` table and is the adapter's default, so an operator writes no mapping of its own.
- 2026-10-08: `refund` reverses a capture by its PaymentIntent, so an operator can give the money back to the card it came from.
- 2026-10-08: `Stripe::ChargeLookup` answers whether a cart mandate was charged, by the metadata the adapter stamps, for reconciling a capture the operator cannot account for.

## [0.5.9] — 2026-10-08

- 2026-10-08: Version 0.5.9, the tree cut that matches skill 0.5.9; this gem's surface is unchanged.

## [0.5.8] — 2026-10-07

- 2026-10-07: Version 0.5.8, the tree cut that matches skill 0.5.8; this gem's surface is unchanged.

## [0.5.7] — 2026-10-07

- 2026-10-07: Version 0.5.7, the tree cut that matches skill 0.5.7; this gem's surface is unchanged.

## [0.5.6] — 2026-10-07

- 2026-10-07: Version 0.5.6, the tree cut that matches skill 0.5.6; this gem's surface is unchanged.

## [0.5.5] — 2026-10-07

- 2026-10-07: Version 0.5.5, the tree cut that matches skill 0.5.5.

- 2026-10-07: **`customer_resolver:` and `customer_saver:` are required**; the mode that charged a presented or `test_payment_method` card without them is gone (K-1994).
- 2026-10-07: **A mapped Customer that Stripe no longer has counts as no saved card**; `setup_url` saves a fresh one through `customer_saver`, which now replaces the mapping (K-1993).
## [0.5.4] — 2026-10-07

- 2026-10-07: **`setup_url` takes the engine's `return_url`, and `setup_return_user_id` names whose human came back**, so the return page is kiosk-server's; the `return_url:` option is gone (T-219).

## [0.5.3] — 2026-10-06

- 2026-10-06: Version 0.5.3, the tree cut that matches skill 0.5.3; this gem's surface is unchanged.

## [0.5.2] — 2026-10-06

- 2026-10-05: **A `return_url:` path is joined to the origin being served**, so on a deployment serving several origins the human returns to the one they came from.

- 2026-10-05: **The derived return URL names the origin being served** (`Kiosk.current_issuer`), not only the default issuer.

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
