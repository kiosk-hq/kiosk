# kiosk-demo-prove — the anonymizing KYC broker demo (kyc.demo.kiosk.tech)

A standalone **anonymizing KYC broker**. Operators need only MINIMAL, ANONYMIZED
facts — "over 18", "holds a category-A driving licence" — never identity or PII.
The broker sits between the many government age/licence services and the many
Kiosk operators: a human authorizes it once, and it returns to the requesting
operator a **signed, anonymized, single-use** claim, bound to that one request.
Each operator trusts the broker as an issuer once; it never registers with every
government service (the broker does), and it never sees a document.

Deploy origin: **kyc.demo.kiosk.tech** (the registered demo domain). The issuer `iss` is env-configurable (`KIOSK_PROVE_ISSUER`)
and defaults to that origin (`https://kyc.demo.kiosk.tech`); the public
verification-URL base (`PROVE_PUBLIC_URL`) defaults to the intake request's own
`base_url` — the origin the request arrived on — **not** the deploy origin. The
two-server harness and specs pin their own local values on both sides.

## Not a Kiosk operator — an ISSUER

The broker mounts **no** Kiosk wire at all — neither of the two reserved
endpoints (`GET <endpoint>/schema`, `POST <endpoint>/pay`) and not one
per-verb endpoint, because it registers no verb. It has no PoW gate, and it
serves no `/.well-known/kiosk.json`. It is the mirror ISSUER
side of the Kiosk trust primitives an operator's `Kiosk::Server::KycVerifier`
already accepts: it signs anonymized attestations that the operator trusts via
the existing `c.kyc_issuer` / `c.kyc_public_key` config — no new framework
surface. It depends on **no** kiosk gem.

## The three legs

| Route | Who → who | Shape |
|-------|-----------|-------|
| `POST /verifications` | operator → broker (server-to-server) | intake: `{operator_id, callback_url, requested_claims, subject_handle}` + `Authorization: Bearer <operator secret>` → `{request_id, verification_url, status:"pending", expires_at}` |
| `GET /verify?request=<id>` | broker → human | the yes/no page (the token is the only credential — no sign-in) |
| `POST /verify` | human → broker | `{request, decision:"approve"\|"decline"}` — on approve mints the claim and POSTs it to `callback_url` |

The callback body the broker POSTs to the operator:

```json
{ "request_id": "<the broker request>", "kyc_jws": "<compact RS256 JWS>", "nonce": "<echo>" }
```

The minted `kyc_jws` payload (the shape the operator's `KycVerifier` accepts):

```json
{ "sub": "<operator user_id>", "iss": "https://kyc.demo.kiosk.tech", "level": "verified",
  "operator": "skooti", "aud": "skooti", "request_id": "…", "nonce": "…",
  "attributes": { "age_over_18": true, "licence_a": true }, "iat": …, "exp": … }
```

## Security model

- **Operator-driven initiation.** A request row can only be created by an
  authenticated operator; a confirmer cannot create one.
- **Unguessable capability.** `request_id` is 256-bit URL-safe random; the
  verification page needs only the token — nothing is enumerable or listable.
- **Bound, single-use, TTL'd claim.** The claim binds to (subject + operator +
  request); a confirmed/declined row is never re-confirmed; an expired row is
  un-confirmable.
- **No replay across operators.** The claim carries `operator`/`aud`; the
  operator's callback handler rejects a claim not addressed to it. The engine
  `KycVerifier` **also** enforces this at the wire: every
  `POST /kiosk/agents/kyc` rejects a claim whose `aud` != the operator's
  `kyc_audience`, so the cross-operator check lives in BOTH the operator
  callback layer and the normative wire.
- **No replay across subjects.** `sub` is the operator's `user_id` for the
  requesting agent; the operator's `KycVerifier` rejects a `sub` mismatch (the
  `IssuedKycJwsTheft` defense, inherited).
- **Anti-mass-confirm.** A confirmer can only ever produce a claim bound to the
  subject the operator named — useful only to that agent at that operator. A
  leaked link is a confined per-subject capability, not a claim factory.
- **SSRF / open-relay guard.** The broker only POSTs to an operator's
  pre-registered callback host (allow-list), never to a free-form URL a caller
  supplies.
- **Request-state-only DB, no re-KYC pre-fill.** `prove_requests` stores only
  per-request STATE (single-use / TTL / no-replay) — never the human's identity
  or prior answers. Each verification is INDEPENDENT: a re-verification (e.g.
  after an agent reset) opens a fresh row with empty checkboxes and the human
  re-asserts every fact. Deliberate — a "verified-once, reuse" store is exactly
  the account-sharing hole the real account-to-person check must prevent, so the
  stub does not model it.

## Demo stub vs. production

This demo **self-asserts** (the human clicks yes/no) and is clearly labelled as
such on the page. It proves the *protocol* — per-request binding, no replay,
anti-mass-confirm, signed anonymized callback — not that the human is actually
over 18, and it makes **no liveness claim**. In production the verification page
is replaced by a **government identity service** login (an mDL / ISO-18013-5
mobile driving licence, an EUDI wallet, or a national IdP), from which the broker
derives the booleans it was asked for. The real broker closes two gaps the stub
leaves open: it verifies the human **possesses a government account** (the
account-possession assurance level adopted for now, after a survey of the
government-IdP / mDL landscape), and later that **the account is
actually theirs** — so a person cannot lend or share their account to vouch for
other people's age or licence. The broker↔operator interface (intake → per-request binding → signed
anonymized callback) is identical, which is why the stub is a faithful proof.
This production path is **research-gated and provisional**: signed mDL issuance is
Kiosk v0.5, not earlier; no named government service is claimed as integrated
today, and no free/assurance claim beyond account-possession is made. Vendor KYC
(Sumsub/Veriff/Onfido) can return age + licence category but **not anonymized**
(bundled with full PII) — which is precisely the gap the broker fills.

## Run

<!-- PREREQS:BEGIN — generated by bin/check-demo-prereqs --write; do not edit by hand -->
### Prerequisites

Generated by `bin/check-demo-prereqs` from this demo's own files — the build fails when
this list and the code that needs it disagree.

**The short way is `docker compose up` in this directory, and it needs none of the list
below.** It builds the image every demo here shares, brings up a Postgres that belongs to
this compose project, and serves the demo on <http://localhost:3020>.
To run one of this demo's own tasks instead of the server:

```
docker compose run --rm app bin/rails <task>
```

The list below is the HOST path — what running `bin/rails demo:*` on your own machine
needs. It is not shorter under containers; it is unnecessary.

- **Ruby 3.2.0 or newer**, then `bundle install` — the floor every kiosk gem declares in its `required_ruby_version`.

> **`demo:setup` is destructive, and every task that depends on it inherits that.**
> It runs `db:drop db:create db:schema:load db:seed` unconditionally — no environment
> check, no confirmation prompt — so running it **DROPS and recreates**
> `kiosk_prove_development`. Nothing you left in that database survives.
> The SERVER is `localhost`, read from the same `config/database.yml` — unless
> `PGHOST` is exported, and then it is whatever host that names: the drop
> follows it, and takes that server's `kiosk_prove_development` instead.
>
> Under `docker compose` the same drop still happens on every `up`, but it lands on the
> Postgres that compose brings up, on this project's own volume. It cannot reach a
> database on your machine: the compose file sets `PGHOST` to the container beside it
> rather than passing yours through.
>
> **`demo:test` DROPS A DIFFERENT DATABASE.** It runs the same
> `db:drop db:create` under `RAILS_ENV=test`, so what it **DROPS and recreates**
> is `kiosk_prove_test` — the `test:` database, not `kiosk_prove_development`.
<!-- PREREQS:END -->

```sh
bundle install
bin/rails demo:setup   # DROPS and recreates the DB, then loads the schema and seeds
bin/rails demo:test    # the broker's own rspec suite
```

<!-- CI-TASKS:BEGIN — generated by bin/check-ci-tasks --write; do not edit by hand -->
### Which of these run in CI

`.github/workflows/ci.yml` runs the tasks marked **yes** on every push and pull
request; the rest are local-only, for the reason given. This table is generated
from the workflow by `bin/check-ci-tasks`, which fails the build when the
workflow, this table and `lib/tasks/demo.rake` disagree — so a task that carries
assertions cannot go ungated and unexplained.

| Task | Runs in CI | Why not |
|---|---|---|
| `demo:setup` | yes — the job's own setup step |  |
| `demo:test` | yes |  |
<!-- CI-TASKS:END -->

The full cross-app flow (operator gates a regulated action via the broker) is
driven by skooti's two-server `demo:kyc`, which boots this broker on its own
port and points skooti's `c.kyc_issuer` / `c.kyc_public_key` at it.
