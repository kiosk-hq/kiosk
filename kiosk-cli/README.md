# kiosk — POSIX shell CLI for Kiosk providers

The `kiosk` command is the primary public API of every Kiosk-enabled provider. It is what an autonomous agent sees and uses.

POSIX shell + `curl` + `jq`. No Ruby, no Node, no Python.

## Install

```sh
curl -fsSL https://kiosk.tech/kiosk | sh
```

Until that URL is live, install from this monorepo:

```sh
cp ./bin/kiosk ~/.local/bin/kiosk && chmod +x ~/.local/bin/kiosk
```

Confirm:

```sh
kiosk --version
```

## Usage

```
kiosk <host> well-known            # GET <host>/.well-known/kiosk.json
kiosk <host> sql <statement>       # POST exec — command: sql
kiosk <host> run <action> [k=v ..] # POST exec — command: run
kiosk --version
kiosk --help
```

`<host>` is the origin (`https://sweepy.example`). The CLI discovers the actual `/exec` endpoint via well-known.

## Output

- TTY: pretty-printed
- Piped to another process: TSV (rows) or raw JSON value (value verbs)
- `--json`: raw envelope JSON

## Exit codes

Per [design spec §5.2](../docs/superpowers/specs/2026-05-04-kiosk-design.md):

| Code | Meaning |
|---|---|
| `0` | ok |
| `2` | syntax / bad request |
| `3` | auth (missing/expired token) |
| `4` | RLS-denied |
| `5` | rate / quota exceeded |
| `6` | server / unknown |

## Token resolution

1. `KIOSK_TOKEN_<HOST_UPPER>` env var, e.g. `KIOSK_TOKEN_SWEEPY_EXAMPLE`
2. `KIOSK_TOKEN` env var (any host)
3. `~/.kiosk/credentials` JSON: `{"https://sweepy.example": {"token": "..."}}`

OAuth 2.1 device-grant `kiosk <host> login` lands in M2 follow-up; until then, populate one of the above.

## What's not in this milestone

- `schema`, `help`, `pay`, `events` verbs — server-side support pending (M3/M4)
- `register`, `login` — OAuth 2.1 surface pending (M2 follow-up)
- `--watch` streaming — depends on SSE backend (M5)
- TSV / pretty-print toggle by `isatty` — basic JSON output for now

## License

Apache-2.0.
