# Kiosk — OSS reference implementation

Apache-2.0 monorepo for [Kiosk](https://kiosk.tech) — the framework that turns a Postgres-backed business app into an AI-assistant surface (REST endpoint, multi-assistant identity per user, app-layer-authorized data plane with opt-in Postgres RLS defense-in-depth, AP2 mandate trail). Where this is heading: [ROADMAP.md](ROADMAP.md).

## Layout

**The gem tables and the demo table are scored on DIFFERENT axes, so their values
are not comparable and the columns are named apart below.** The gems carry **API
stability**: `alpha` is pre-v1.0 — the surface may still change between releases —
which is the same thing each gem's own README says about itself. The demos carry
**deployment**: `active` means the entry is gated on every CI run and, for the eight
demo apps, live at its own subdomain. A demo being `active` says nothing about how
settled the `alpha` engine underneath it is.

### Core framework

| Gem | Purpose | API stability |
|---|---|---|
| `kiosk-core` | Value types, abstract bases, GUC constants, configuration. No Rails dep. | alpha |
| `kiosk-rls` | Opt-in RLS DSL + migration helpers (`rake kiosk:rls:{show,check}` planned, lands in a follow-up) | alpha |
| `kiosk-server` | Rails engine, routes, kiosk-pop auth surface, executor | alpha |
| `kiosk-all` | Meta-gem; `bundle add kiosk-all` installs core + server | alpha |
| `kiosk-test-support` | Shared test helpers, factories, RSpec matchers | alpha |

### Plugins & adapters

| Gem | Purpose | API stability |
|---|---|---|
| `kiosk-rls-rspec` | RSpec journey-test helpers for RLS policies | alpha |
| `kiosk-rls-minitest` | Minitest journey-test helpers for RLS policies | alpha |
| `kiosk-user-idp-devise` | User-IdP adapter (Devise) | alpha |
| `kiosk-pay-stripe` | PSP adapter — Stripe, AP2 mandate trail | alpha |

### Proof-of-work

| Gem | Algorithm | Solver memory | Default? |
|---|---|---|---|
| `kiosk-pow-equihash` | Equihash (n=168, k=7) | ~1.3 GiB | ✅ |
| `kiosk-pow` | Argon2id (D=0..256) | 64 MiB | legacy |
| `kiosk-pow-cuckoo` | Cuckatoo29 | ~4 GiB | no |

See `kiosk-pow-equihash/README.md` for the full comparison and rationale.

### Reputation & security

| Gem | Purpose | API stability |
|---|---|---|
| `kiosk-reputation` | Customer reputation factors + bad-proof signal | alpha |
| `kiosk-redteam` | Red-team scenarios, adversarial test harness | alpha |

### Demo providers

| Demo | Vertical | Deployment |
|---|---|---|
| `kiosk-demo-getgrocery` | Grocery delivery | active |
| `kiosk-demo-atablefor` | Restaurant table-booking — non-commerce (no payments) | active |
| `kiosk-demo-hoteling` | Hotel booking | active |
| `kiosk-demo-skooti` | Scooter rental | active |
| `kiosk-demo-stylish` | Salon/appointment booking (Combette on Park) — non-commerce (no payments) | active |
| `kiosk-demo-philslist` | Classifieds board — non-commerce (no payments) | active |
| `kiosk-demo-tudu` | Collaborative todo — non-commerce (no payments) | active |
| `kiosk-demo-prove` | anonymizing KYC broker (deploys at `kyc.demo.kiosk.tech`) — an ISSUER, not a Kiosk operator (no verbs) | active |
| `e2e` | End-to-end test fixtures, stub PSP, AI-assistant pay flow | active |

Each demo exposes a set of `rake demo:*` tasks. Not all of them are CI gates —
some are heavy or timing-sensitive local showcases. Which is which is stated in
every demo README's **"Which of these run in CI"** table, generated from
`.github/workflows/ci.yml` by `bin/check-ci-tasks`; that script also runs as its
own CI job and fails the build when a `demo:` task is neither gated nor recorded
with the reason it is not — or when a task the demo defines is not named in that
README's own hand-written list of what each task proves.

**Four of the demos — `atablefor`, `getgrocery`, `hoteling`, `skooti` — also
carry a `before-after.md`**: a long-form contrast between what an AI assistant
can do at that provider today and what the same errand looks like once Kiosk is
installed, followed by the operator-side adoption recipe. Four rather than all
eight is deliberate and it is machine-held there. The long form is expensive to
keep honest: every fenced block in it must declare the rake task or source file
it came from, and `bin/check-demo-derivations` (its own CI job) then holds each
transcript line to a literal that task actually prints and each snippet line to
a line of the file it quotes. `bin/check-demo-copies` asserts the set is exactly
those four, so a fifth cannot appear — or a fourth vanish — unannounced. The
rest say it shorter: `philslist` carries an inline **Before / after** section in
its README; `stylish` and `tudu` carry neither.

The demos are standalone Rails apps, so a helper two of them need is COPIED, not
shared. `bin/check-demo-copies` — its own CI job too — declares every
hand-written Ruby file that exists in more than one demo, plus `.gitignore`, as
kept identical, kept identical apart from its header prose, or a deliberate
per-demo variant, each with the reason; it fails the build when copies that must
agree stop agreeing, and when a new duplicate turns up undeclared. Header prose
may vary, but a magic comment may not: `# frozen_string_literal: true` changes
how the file runs, so it is compared. The Rails skeleton each demo edits for its
own port and host is out of scope on purpose, and that exclusion is recorded
file by file, with its reason, in the same script.

Everything in this repo consumes the gems by `path:`, which serves the working
tree — so nothing here can tell a file that EXISTS from a file that is
PACKAGED, and kiosk-server shipped without its view templates for exactly that
reason. `bin/check-gem-packaging` — its own CI job as well — builds every `*.gemspec` in
this repo and reads the file list back out of the built `.gem`. It fails when a tracked
file is neither in the package nor declared development scaffolding with the
reason, and when packaged Ruby resolves a `__dir__`-relative path to something
the package does not contain. Adding a non-`lib/` file a gem needs at runtime
means adding it to that gem's `spec.files`.

## Contributing

- One `bundle install` at the gem root covers that gem
- One `bundle exec rspec` runs that gem's specs
- Aggregated tasks across the monorepo land later (planned)
- See per-gem README for gem-specific dev notes

Every gem shares the protocol's MAJOR.MINOR — the version parity the spec
promises ([protocol §14.1](https://kiosk.tech/spec/protocol.md)): the protocol,
this reference implementation and the published skill all read `0.4` today, so
`Kiosk-Server-Version` and `Kiosk-API-Version` agree on the line they speak.
PATCH stays per-gem, so one gem can ship `0.4.4` while its sibling sits at
`0.4.0`. `bin/check-version-parity` — its own CI job — enforces exactly that
against `Kiosk::Protocol::API_VERSION`, including the `~> 0.4.0` inter-gem
constraints in the gemspecs and the pinned `skill_url`. Releases are cut as
path-scoped git tags (e.g. `kiosk-core/v0.4.0`) off each subdir's authoritative
`*.gemspec`.

## License

Apache-2.0 for every gem in this repo. See each gem's `LICENSE.txt`.

Commercial gems (regional PSPs, enterprise-IdP tiers) are planned to live in separate repos under the `kiosk-hq` org, outside this Apache-2.0 monorepo. None exist yet.

## Links

- [kiosk.tech](https://kiosk.tech) — landing page + AI-assistant skill
- [kiosk.tech/skill.md](https://kiosk.tech/skill.md) — universal AI-assistant skill
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
