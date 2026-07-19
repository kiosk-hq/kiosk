# Kiosk — OSS reference implementation

Apache-2.0 monorepo for [Kiosk](https://kiosk.tech) — the framework that turns a Postgres-backed business app into an agent surface (REST endpoint, multi-agent identity per user, app-layer-authorized data plane with opt-in Postgres RLS defense-in-depth, AP2 mandate trail).

## Layout

### Core framework

| Gem | Purpose | Status |
|---|---|---|
| `kiosk-core` | Value types, abstract bases, GUC constants, configuration. No Rails dep. | alpha |
| `kiosk-rls` | Opt-in RLS DSL + migration helpers (`rake kiosk:rls:{show,check}` planned, lands in a follow-up) | alpha |
| `kiosk-server` | Rails engine, routes, kiosk-pop auth surface, executor | alpha |
| `kiosk-all` | Meta-gem; `bundle add kiosk-all` installs core + server | alpha |
| `kiosk-test-support` | Shared test helpers, factories, RSpec matchers | alpha |

### Plugins & adapters

| Gem | Purpose | Status |
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

| Gem | Purpose | Status |
|---|---|---|
| `kiosk-reputation` | Customer reputation factors + bad-proof signal | alpha |
| `kiosk-redteam` | Red-team scenarios, adversarial test harness | alpha |

### Demo providers

| Demo | Vertical | Status |
|---|---|---|
| `kiosk-demo-getgrocery` | Grocery delivery | active |
| `kiosk-demo-foodelivery` | Restaurant delivery | active |
| `kiosk-demo-hoteling` | Hotel booking | active |
| `kiosk-demo-skooti` | Scooter rental | active |
| `kiosk-demo-stylish` | Salon/appointment booking (Combette on Park) | alpha |
| `kiosk-demo-philslist` | Classifieds board — non-commerce (no payments) | active |
| `kiosk-demo-tudu` | Collaborative todo — non-commerce (no payments) | active |
| `e2e` | End-to-end test fixtures, stub PSP, agent pay flow | active |

## Contributing

- One `bundle install` at the gem root covers that gem
- One `bundle exec rspec` runs that gem's specs
- Aggregated tasks across the monorepo land later (planned)
- See per-gem README for gem-specific dev notes

Per-gem versioning is independent — path-scoped git tags (e.g. `kiosk-core/v0.5.0`) and each subdir's authoritative `*.gemspec`.

## License

Apache-2.0 for every gem in this repo. See each gem's `LICENSE.txt`.

Commercial gems (regional PSPs, enterprise-IdP tiers) are planned to live in separate repos under the `kiosk-hq` org, outside this Apache-2.0 monorepo. None exist yet.

## Links

- [kiosk.tech](https://kiosk.tech) — landing page + agent skill
- [kiosk.tech/skill.md](https://kiosk.tech/skill.md) — universal agent skill
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
