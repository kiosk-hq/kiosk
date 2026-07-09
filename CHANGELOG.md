# Changelog

Significant changes only (CLAUDE.md rule 5): one line per change, 1–2
sentences — essence and intent, not content.

- 2026-07-09: Adopted the Kiosk 0.1 convergence process: repo constitution in CLAUDE.md (five rules), workspace-level findings/TODO ledgers, and a repo-wide CI workflow running every gem suite, demo happy-path/isolation/redteam flows, and e2e. (PLAN.md at the workspace root)
- 2026-07-09: Discovery `/.well-known/kiosk.json` now advertises `capabilities` as verb names (schema/query/run/pay) computed from the registry, replacing the static `[query,actions,ap2]`. (ADR-0009, K-017)
- 2026-07-09: Registration accepts an optional provider `assistant_creation` factory so hosts with a validated account model no longer 500 on agent sign-up. (ADR-0010, K-029)
- 2026-07-09: AP2 mandate verification now requires all six spec-mandated claims (id, user_id, agent_id, iss, iat, exp), not exp alone — a mandate missing id/iat is rejected. (K-020)
- 2026-07-09: Corrected gem READMEs and the equihash PoW cost claims to shipped reality (kiosk-server shipped; equihash is the default; canonical N×PoW reputation wire; honest ~16 ms/few-KB verify). (K-004..K-008, K-033)
