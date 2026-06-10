# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `bin/kiosk` — POSIX shell entry point. Verbs `well-known`, `sql`, `run`. Flags `--json`, `--help`, `--version`.
- Token resolution: per-host env (`KIOSK_TOKEN_<HOST_UPPER>`), generic env (`KIOSK_TOKEN`), then `~/.kiosk/credentials` JSON map.
- Well-known discovery: every non-well-known verb resolves `kiosk.endpoint` via `<host>/.well-known/kiosk.json` and posts against `${endpoint}/exec`.
- Exit-code mapping per spec §5.2: `0` ok / `2` bad_request | not_found / `3` unauthenticated / `4` forbidden | rls_denied / `5` quota_exceeded / `6` server | action_failed | network.
- `install.sh` — POSIX installer; detects `$XDG_BIN_HOME` or falls back to `~/.local/bin`; chmod +x; warns if target dir not on `PATH`.
- `test/run.sh` — POSIX test harness with `assert` helper; runs against a mock HTTP server (`test/mock_server.sh`).

### Out of scope for first release

- `schema`, `help`, `pay`, `events` verbs — pending server support.
- `register`, `login` — pending OAuth 2.1 surface in `kiosk-server` (M2 follow-up).
- `--watch` SSE streaming — pending Tier-1 events transport (M5).
- TTY-vs-pipe output auto-switching (TSV vs pretty table) — current release emits a single JSON-leaning format with `--json` toggle.
