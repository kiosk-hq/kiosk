# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `bin/kiosk` — POSIX shell entry point. Verbs `login`, `well-known`, `sql`, `run`. Flags `--json`, `--help`, `--version`.
- **`kiosk <host> login`** — RFC 8628 Device Authorization Grant client. Initiates `POST /oauth/device_authorization`, displays the user_code + verification URL prominently, optionally auto-opens browser via `open` / `xdg-open` (skipped when `KIOSK_NO_BROWSER=1` or stdout is not a TTY), polls `POST /oauth/token` at the server-advertised interval, respects `slow_down` (bumps interval by 5s), exits with the matching error code on `access_denied` (3), `expired_token` (6), etc. On success, atomically writes the bearer to `~/.kiosk/credentials` with `chmod 0600`. Env overrides: `KIOSK_CLIENT_ID` (default `kiosk-cli`), `KIOSK_NO_BROWSER`.
- Token resolution: per-host env (`KIOSK_TOKEN_<HOST_UPPER>`), generic env (`KIOSK_TOKEN`), then `~/.kiosk/credentials` JSON map.
- Well-known discovery: every non-well-known verb resolves `kiosk.endpoint` via `<host>/.well-known/kiosk.json` and posts against `${endpoint}/exec`.
- Exit-code mapping per spec §5.2: `0` ok / `2` bad_request | not_found / `3` unauthenticated / `4` forbidden | rls_denied / `5` quota_exceeded / `6` server | action_failed | network.
- `install.sh` — POSIX installer; detects `$XDG_BIN_HOME` or falls back to `~/.local/bin`; chmod +x; warns if target dir not on `PATH`.
- `test/run.sh` — POSIX test harness with `assert` helper; runs against a mock HTTP server (`test/mock_server.sh`).

### Out of scope for first release

- `schema`, `help`, `pay`, `events` verbs — pending server support.
- `register` (one-time agent identity creation, RFC 7591 DCR) — pending OAuth surface in `kiosk-server`.
- `--watch` SSE streaming — pending Tier-1 events transport (M5).
- TTY-vs-pipe output auto-switching (TSV vs pretty table) — current release emits a single JSON-leaning format with `--json` toggle.
