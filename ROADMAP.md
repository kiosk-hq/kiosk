# Roadmap

Directions after the current release — intentions, not commitments, in rough
order of pull. Each lands only with the same bar the shipped surface holds:
demonstrated behavior, adversarial coverage, spec text where the wire changes.

- **Client-preferred currency.** An operator cannot dictate the customer's
  currency. The direction: the assistant declares its preferred currency, and
  the kiosk serves catalog prices in it (or names the currencies it can
  settle in). Today an operator prices in one currency, advertises it on its
  catalog, and rejects carts denominated in anything else — correct, but
  single-currency. Wire-level currency negotiation is deliberately
  post-release.
- **More human-login adapters.** A Devise adapter ships as the worked
  example; Warden, OIDC, SAML, and custom-session adapters are the same
  small shape.
- **Turnkey KYC issuance.** The attestation verifier and attribute gates are
  shipped; issuing attestations through an existing KYC provider (Persona,
  Sumsub, or the operator's own) is the missing half.
- **MPP as a settlement adapter.** Kiosk is payment-rail agnostic; the
  reference ships Stripe card-on-file. Evaluating MPP (Stripe + Tempo)
  sessions as an alternative rail — an adapter, not a protocol change.
- **External agent-identity issuers.** Today an assistant self-registers
  with its own keypair (proof-of-possession). Fronting the agent side with
  an external identity issuer that asserts an assistant's identity directly
  is a planned seam.
- **Durable token revocation.** Revocation is an in-process watermark today;
  a durable store survives restarts.
- **Key rotation.** A first-class ceremony for an assistant to roll its
  keypair without losing its account or reputation.
- **Operator-push events.** The operator tells the assistant something
  changed instead of waiting to be polled: a slot moved; a saved card is
  ready (today the assistant relays a card-entry link and then polls for the
  human to finish, though the PSP already fires a webhook on card-saved); a
  booking confirmed; or a classifieds buyer wants to reach a listing's poster
  (today the only channel is a phone number in the listing body).
- **Ports beyond Ruby.** The wire is HTTPS + JSON + JWS — nothing
  Ruby-specific. The formal spec and JSON Schemas at kiosk.tech exist for
  porters; a Go, Python, or Node provider implementation is a welcome
  contribution, not a fork.
