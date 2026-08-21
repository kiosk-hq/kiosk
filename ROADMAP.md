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
- **Uniform request validation.** Most of this layer shipped in 0.4 and what
  is left is narrow. SHIPPED: the opt-in `c.validate_requests` flag (on in the
  demos) validates the proof(s) parsed from the `Kiosk-PoW` request header
  against the normative PoW JSON Schema, so a malformed proof returns a clear
  `400 bad_request` with a shape hint instead of a silent re-issued `402` loop
  (closed K-479); per-verb `input_schema` validation of a request's coerced
  arguments, which is **unconditional** rather than flag-gated, because
  `input_schema` is required on every 0.4 verb and a flag would leave the typed
  `400` existing on some origins and not others; a helpful `405
  method_not_allowed` carrying `Allow` and a hint when a verb is dialed with
  the wrong method; a CI conformance test that validates a live origin's
  RESPONSE bytes against the published JSON Schemas
  (`e2e/schema_conformance.rb`, run by `e2e/run.sh`); and a sync-check that the
  vendored schema copies match the normative `kiosk.tech/spec/schemas/`
  originals (`bin/check-spec-schemas`). STILL OPEN: JSON Schemas for the auth
  plane, which has none, and a structured field-path `detail` on a validation
  problem document, so a caller can locate the offending argument without
  parsing prose.
- **More human-login adapters.** A Devise adapter ships as the worked
  example; Warden, OIDC, SAML, and custom-session adapters are the same
  small shape.
- **KYC as anonymized minimal claims.** The attestation verifier and attribute
  gates are shipped, and a demo issuer (`kiosk-demo-prove`, at kyc.demo.kiosk.tech)
  mints signed anonymized booleans ("over 18", "holds a category-A licence")
  from a human's yes/no confirmation — the operator never sees the documents.
  Operators need only these minimal facts, never full identity, so the missing
  half is not a full-KYC vendor but a broker that turns a government credential
  into a minimal claim. The demo broker **self-asserts** — the human ticks the
  boxes, and both of its pages say so — which proves the protocol (per-request
  binding, no replay, signed anonymized callback) and nothing about the human.
  A real broker replaces that page with a government identity service login and
  closes two gaps in order: first that the human possesses a government account
  (account-possession), then that the account is actually theirs (liveness, so
  an account cannot be shared to vouch for others). Sourcing the underlying
  claim from a mobile driving licence
  (mDL / ISO 18013-5, which natively carries selective-disclosure age and
  licence-category) is targeted for a later release (~v0.5, US wallet path
  first); other national identity systems (EU EUDI, UK, Canada, Australia) are
  further out and pilot-stage today.
- **MPP as a settlement adapter.** Kiosk is payment-rail agnostic; the
  reference ships Stripe card-on-file. Evaluating MPP (Stripe + Tempo)
  sessions as an alternative rail — an adapter, not a protocol change.
- **External agent-identity issuers.** Today an assistant self-registers with
  its own keypair (proof-of-possession) and the bundled engine verifies the
  tokens it minted. The seam for fronting that with an external issuer is
  built — `Kiosk::AgentIdentityProviders::Base` plus the `c.agent_idp`
  override — but nothing is written against it yet (Entra Agent ID, Okta Agent
  Identity, Google Agent Passport, ID-JAG); the adapter is the work.
- **Durable token revocation.** The seam ships — `c.revocation_store` takes
  any object answering `revoke_all` / `revoked?` / `watermark_for` — but the
  bundled store is an in-process per-agent watermark: not shared across web
  workers, and gone on restart. What is missing is a durable implementation,
  whose provisioned home is the `agent_tokens` table.
- **Key rotation.** Neither side can roll a key without a break. The JWKS
  document builder takes a list and would carry an outgoing and an incoming
  operator key through an overlap window, but the served document is built from
  the one configured `signing_key`, so there is no overlap to publish into. On
  the assistant side there is not even a shape: rolling its keypair means
  registering a new identity and starting over on reputation. Both want a
  first-class ceremony; the assistant's is the one that costs a customer.
- **Operator-push events.** The operator tells the assistant something
  changed instead of waiting to be polled: a slot moved; a saved card is
  ready (today the assistant relays a card-entry link and then polls for the
  human to finish, though the PSP already fires a webhook on card-saved); a
  booking confirmed; or a classifieds buyer wants to reach a listing's poster
  (today there is no channel at all — the board carries no contact field and no
  message verb, so a match an assistant finds has nowhere to go).
- **Ports beyond Ruby.** The wire is HTTPS + JSON + JWS — nothing
  Ruby-specific. The formal spec and JSON Schemas at kiosk.tech exist for
  porters; a Go, Python, or Node provider implementation is a welcome
  contribution, not a fork.
