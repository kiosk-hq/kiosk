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
- **KYC as anonymized minimal claims.** The attestation verifier and attribute
  gates are shipped, and a demo issuer (`prove.my`, at kyc.demo.kiosk.tech)
  mints signed anonymized booleans ("over 18", "holds a category-A licence")
  from a human's yes/no confirmation — the operator never sees the documents.
  Operators need only these minimal facts, never full identity, so the missing
  half is not a full-KYC vendor but a broker that turns a government credential
  into a minimal claim. In this release the broker proves the human possesses a
  government account (account-possession); binding the account to the person
  (liveness, so an account cannot be shared to vouch for others) is a later
  hardening. Sourcing the underlying claim from a mobile driving licence
  (mDL / ISO 18013-5, which natively carries selective-disclosure age and
  licence-category) is targeted for a later release (~v0.5, US wallet path
  first); other national identity systems (EU EUDI, UK, Canada, Australia) are
  further out and pilot-stage today.
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
