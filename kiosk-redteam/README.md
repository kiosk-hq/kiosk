# kiosk-redteam

Adversarial regression harness for [Kiosk](https://kiosk.tech) providers — it
drives hostile HTTP scenarios against a running Kiosk origin and asserts each
attack is correctly blocked.

## What it does

A scenario registers its own principals over the wire, stages whatever state the
attack needs, then performs the attack and returns a `Verdict`. A scenario that
finds a real breach fails loudly: `Runner#all_blocked?` answers false and the
caller exits non-zero. Fix the provider, keep the scenario as a permanent
regression.

**No Rails, no `kiosk-core`.** The harness speaks the wire and nothing else, so
it can be pointed at any Kiosk origin — your own app in CI, or a third party's
deployment. Everything provider-specific (which verbs exist, how to create an
owned row, how to build a mandate) lives in a `Profile` you supply; no provider
name is hard-coded in the gem.

### Blocked, breached, skipped — the three states

| Verdict | Means | Printed |
|---|---|---|
| **blocked** | the provider refused this attack | `BLOCKED ✓ <name> (HTTP <status>)` |
| **breach** | the attack was NOT refused — a real finding | `BREACH  ✗ <name> — <detail>` |
| **skipped** | the profile lacks the surface this scenario needs | `SKIP    — <name> (<reason>)` |

A skip is a distinct third state, **not** a pass: it does not count towards the
blocked total, and `Runner#all_blocked?` refuses to go green on a battery that
produced no proofs at all, so a profile that skips everything cannot exit 0.

What counts as a refusal is deliberately narrow. HTTP 401/403 count, and so do
the problem document `code`s `forbidden` / `unauthenticated` / `rls_denied`.
**5xx never counts** — a crash must not masquerade as an enforcement gate. Nor
does **402**: `kiosk-server` maps three codes onto that status
(`pow_required`, `payment_setup_required`, `payment_failed`) and two of them are
not refusals of anything, so a 402 yields a "could not test" verdict unless the
scenario named the code it accepts. A scenario that knows which gate must fire
says so with `expect:` / `expect_code:` rather than leaning on the permissive
default.

## Install

```ruby
# Gemfile — a test/CI dependency, not a runtime one
gem "kiosk-redteam", group: :development
```

The registration toll is real Equihash: the client solves the server's 402
challenges by shelling out to the reference solver that ships inside
`kiosk-pow-equihash` (a runtime dependency of this gem), so the machine running
the battery needs **`python3` with `numpy`** on `PATH`. Point a battery at an
origin whose PoW is off and nothing is solved and nothing is needed.

## Usage

Describe the provider once, hand the runner a list of scenarios, exit on the
verdict:

```ruby
require "kiosk/redteam"

SERVER = ENV.fetch("SERVER_URL", "http://127.0.0.1:3000")

profile = Kiosk::Redteam::Profile.new(
  # >0 means this origin is expected to gate /auth/register with Equihash.
  pow_difficulty: 1,
  # The roles this origin declares (Kiosk.configuration.roles), as strings.
  declared_roles: %w[customer],
  # The named query that returns the caller's OWN rows.
  per_user_query: "my_orders",
  # Key in a returned row that holds the row id, and in an action's own
  # response object (they often differ).
  row_id_key:     "id",
  result_id_key:  "order_id",
  # Create a row owned by `principal`; must return a Hash with at least :id.
  create_owned:   ->(client, principal) {
    resp = client.run(principal, name: "create_order", items: [{ sku: "SKU-1", qty: 1 }])
    raise "create_order failed (#{resp.status}): #{resp.body.inspect}" unless resp.status == 200
    { id: resp.body.fetch("order_id") }
  },
  # An action that takes a `user_id` argument the server must NOT honour.
  forge_action:   "create_order",
  forge_args:     ->(_client, _a, _b) { { items: [{ sku: "SKU-1", qty: 1 }] } },
)

runner = Kiosk::Redteam::Runner.new(base_url: SERVER, profile:)
runner.run([
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
])

exit 1 unless runner.all_blocked?
```

Use `exit 1 unless runner.all_blocked?`, **not** `exit 1 if runner.breaches.any?`
— `breaches` answers `[]` for a battery that never ran, so the second form exits
0 on a gate that did nothing.

Every field of `Profile` is optional; a scenario whose field is `nil` skips
itself rather than inventing a surface. That is what lets one battery cover a
commerce provider and a non-commerce one. Every operator demo in this repo ships
a `script/redteam_suite.rb` built on this API — read one of those for a worked,
running profile against a real origin.

## The scenario library

The classes under `Kiosk::Redteam::Scenarios`, each parameterised entirely by
the profile — this is the whole library, `lib/kiosk/redteam/scenarios/` has one
file per row:

| Scenario | Category | Asserts |
|---|---|---|
| `CrossTenantRead` | authorization | B's per-user query must not return rows owned by A |
| `ForgedUserId` | authorization | a caller-supplied `user_id` never decides ownership |
| `PrivilegeSelfSelection` | authorization | a client-chosen registration role is ignored — the role is server-pinned |
| `DeviceGrantRoleSelfSelection` | authorization | the claim ceremony's unauthenticated opening request refuses `role`/`scope`, at a DECLARED value as well as an invented one |
| `SpentResourceReuse` | authorization | a consumed resource cannot be re-activated |
| `PayForOtherUseSelf` | authorization | B paying for A's resource does not let B use it |
| `TokenTampering` | authentication | a JWT with a flipped claim and the original signature is 401 |
| `RegistrationWithoutPow` | registration | a missing or bad proof is rejected when the origin charges a toll |
| `MandatePrincipalSwap` | mandate | B signing a mandate that carries A's identity is rejected |
| `MandateReplay` | mandate | A's signed mandate JWS re-submitted under B's token is rejected |
| `UnpaidGatedAction` | payment | the gated action without a prior settled payment is denied |
| `MissingKyc` | kyc | the gated action after payment but without an attestation is denied |
| `ExpiredKyc` | kyc | an attestation whose `exp` has passed is rejected |
| `ForgedKyc` | kyc | an attestation with a wrong issuer or a bad signature is rejected |

Beside them the gem ships `Client` (register + PoW payment, kyc, query / run /
pay with RS256 mandate signing, and the OAuth device-authorization request),
`Profile`, `Scenario`, `Verdict`, `Response`, `Principal`, `Runner` and
`LeakScan` — the shared oracle that decides whether a refusal leaked the
runtime's own vocabulary, discounting needles the probe itself supplied.

### Writing your own

Subclass `Scenario`, name what you are attacking, and return a `Verdict` that
says which gate you demanded:

```ruby
class UnknownVerbIs404 < Kiosk::Redteam::Scenario
  def initialize
    super(name:        "UnknownVerbIs404",
          category:    "dispatch",
          description: "an unregistered verb name is a 404, never a 500")
  end

  def call(client, profile)
    principal = register_principal(client, name: "redteam-unknown", profile:)
    verdict_from(client.query(principal, name: "no_such_verb"), expect: 404)
  end
end
```

## Status

Pre-v1.0 alpha. The `Scenario` / `Profile` / `Verdict` surface is stable across
pre-v1.0 minor bumps; the scenario library grows as gates are added
(`CHANGELOG.md` tracks).

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech) — landing + docs
- [Specification](https://kiosk.tech/specification.html) — the normative spec
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
