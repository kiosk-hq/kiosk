# Kiosk — OSS gems monorepo

Apache-2.0 monorepo for [Kiosk](https://kiosk.tech) — the framework that turns a Postgres-backed business app into a production-grade agent surface (MCP endpoint, multi-agent identity per user, RLS-protected data plane, AP2 mandate trail, structured audit).

## Layout

| Gem | Purpose | Status |
|---|---|---|
| `kiosk-core` | Value types, abstract bases, GUC constants, configuration. No Rails dep. | alpha |
| `kiosk-rls` | RLS DSL + migration helpers + `rake kiosk:rls:{show,check}` | planned (M1) |
| `kiosk-server` | Rails engine, routes, OAuth 2.1 surface, executor | planned (M1-M3) |
| `kiosk-rls-rspec` / `kiosk-rls-minitest` | Journey-test helpers | planned (M3) |
| `kiosk-all` | Meta-gem; `bundle add kiosk-all` installs the family | planned (M3) |
| `kiosk-user-idp-devise` | First user-IdP adapter | planned (M2) |
| `kiosk-pay-stripe` | First PSP adapter — AP2 mandate trail | planned (M4) |
| `kiosk-credentials-persona` | First KYC broker adapter | planned (M5) |
| `kiosk-agent-test` | Live-LLM journey-test companion | planned (M6) |
| `kiosk-credentials-all` | Multi-region KYC umbrella | planned (M6) |
| `kiosk-cli` | POSIX-shell CLI binary (`bin/kiosk`) + `install.sh` | alpha (M2) |
| `kiosk-website` | Landing + docs site source (Astro) | planned (M5-M6) |
| `kiosk-demo-saas-booking` | Sweepy reference demo — `rake demo` shows the full wire surface in ~30s | alpha (M3) |

## Contributing

- One `bundle install` at the gem root covers that gem
- One `bundle exec rspec` runs that gem's specs
- Aggregated tasks across the monorepo land later (planned)
- See per-gem README for gem-specific dev notes

Per-gem versioning is independent — path-scoped git tags (e.g. `kiosk-core/v0.5.0`) and each subdir's authoritative `*.gemspec`.

## License

Apache-2.0 for every gem in this repo. See each gem's `LICENSE.txt`.

Commercial gems (regional PSPs, enterprise-IdP tiers) live in separate private repos under the `kiosk-hq` org and are not part of this monorepo. See [kiosk.tech](https://kiosk.tech) for licensing details.

## Links

- [kiosk.tech](https://kiosk.tech) — landing + docs
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
