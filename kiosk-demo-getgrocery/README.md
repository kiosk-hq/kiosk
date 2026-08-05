# kiosk-demo-getgrocery

Grocery delivery demo operator for Kiosk.

Single implicit store (getgrocery IS the store): catalog / delivery_slots /
my_orders queries, create_order / reschedule_delivery / payment_setup actions
(delivery slot + address are part of create_order), real Stripe SetupIntent
card-on-file payments (stripe-mock when no key is set) behind a cashier check
(the cart must be EUR, mirror the order at catalog prices, and sum correctly),
and the claim-rebind half of the account-binding ceremony.

## Flows

```sh
cd kiosk-demo-getgrocery
bundle install
rake demo            # setup + shop: no-human register → order (slot+address) → pay
```

| Task | What it proves |
|---|---|
| `rake demo:setup` | idempotent db drop / create / load / seed |
| `rake demo:shop` | no-human happy path: register → catalog → delivery_slots → create_order (delivery slot + address required) → payment_setup → pay (cart mirrors the order at catalog EUR prices, off_session PaymentIntent) → my_orders (paid) |
| `rake demo:claim` | claim-rebind: a standalone assistant (own key, own synthetic account, `payment_setup → setup_required`) is re-bound to the seeded human's account after verify-page approval — agent_id stays, user_id remaps, the old order is NOT migrated — then pays a new order with the human's saved card (`payment_setup → ready`) |
| `rake demo:isolation` | adversarial cross-tenant + order-ownership denial |
| `rake demo:schema` | self-discovery over the schema verb |
| `rake demo:redteam` | kiosk-redteam battery — 12 attacks BLOCKED (incl. the cashier-check trio: wrong-currency, tampered-price, inflated-total carts), 3 generic KYC scenarios skip (the age-gate is exercised by `demo:agecheck`) |
| `rake demo:agecheck` | alcohol 18+ age-gate via the prove.my broker (two-server): alcohol order without KYC → 403 → request_kyc → broker approve → 200 → pay; non-alcohol order needs no KYC (200 directly); forged age attestation rejected |
| `rake demo:pow` | catalog-toll PoW: 402 → solve → 200 |

## Age-restricted purchases (anonymized KYC)

One catalog item is age-restricted (a coined wine — no real brand). A cart
containing it can only be ordered (`create_order`) by an agent that has
completed an 18+ anonymized-KYC check via the shared **prove.my** broker
(`run request_kyc` → human approves a broker link → the broker signs an
anonymized `{age_over_18}` claim → submit it to `POST /kiosk/agents/kyc`).
Non-restricted groceries need no KYC. `rake demo:agecheck` drives the full
two-server flow.

This age-gate is the **proper home** of anonymized KYC: a low-liability
*eligibility* check where the transaction closes. Anonymized KYC confirms a
fact (over 18) without identifying the person — so it does **not** confer
accountability, which is exactly why it is used here (eligibility) and NOT for
high-liability actions where the operator needs to know *who* is on the hook.
(getgrocery is a second broker operator; deploy allow-listing is a follow-up.)

Payments need `STRIPE_SECRET_KEY` (sk_test_…, real test-mode charge) or a
local stripe-mock — the tasks self-start one when no key is set; export
`STRIPE_MOCK_URL=http://localhost:12111` to boot the app secret-free.
`demo:claim` always runs against stripe-mock: the human's saved card is a
seeded `stripe_customers` mapping served by the mock's card fixture, so no
real customer exists to charge.

The human side of the claim ceremony (verify page, link mint, unlink)
authenticates through a stub web-session channel (`lib/stub_user_idp.rb`) —
this demo ships no human login UI. See kiosk-demo-stylish for the same
ceremony over real Devise sessions.
