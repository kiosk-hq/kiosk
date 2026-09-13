# Contributing to Kiosk

Thanks for looking. This is the reference implementation of the Kiosk protocol:
a Ruby gems monorepo, eight demo Rails applications that exercise it, and an
end-to-end harness that builds a fresh app from scratch and drives it over HTTP.
The protocol itself is specified at [kiosk.tech](https://kiosk.tech) and the
specification is normative — code and documents conform to it, not the other way
round.

**Found a security flaw? Open an issue — and read [SECURITY.md](SECURITY.md)
first**, because a GitHub issue is public from the moment you file it and that
page says so, names the repository each kind of report goes to, and says what a
useful report carries.

## What to open, and where

| You have | Open |
|---|---|
| A bug in a gem, a demo or the harness | An [issue](https://github.com/kiosk-hq/kiosk/issues) |
| A question about the protocol, or a disagreement with the spec | An issue, and quote the section you are arguing with |
| A security vulnerability in the implementation | An [issue here](https://github.com/kiosk-hq/kiosk/issues) — read [SECURITY.md](SECURITY.md) first; it is public the moment you file it |
| A security vulnerability in the specification | An [issue on `kiosk-hq/kiosk.tech`](https://github.com/kiosk-hq/kiosk.tech/issues) — same page, same caveat |
| A fix you have already written | A pull request, with the gate below green |

A bug report is most useful with the commit you were on, the gem or demo it is
in, and the shortest command that shows it — a failing spec is the best kind of
report there is.

## Getting set up

Everything here is measured against the machine that runs it; nothing is pinned
in the repository (`.ruby-version` and `mise.toml` are gitignored so you manage
your own toolchain — `kiosk-demo-getgrocery/mise.toml.example` is the tracked
template).

- **Ruby.** Every gemspec declares `required_ruby_version >= 3.2.0`, and CI runs
  both ends: one leg on the declared floor, read out of a gemspec at job time,
  and one on the newest release the demos run.
- **PostgreSQL.** The kiosk schema, the identity tables and the optional RLS
  backstop are Postgres. Running the demos additionally needs the privilege to
  `CREATE ROLE` — managed Postgres and shared dev servers refuse it.
- **Python 3 with numpy.** Only for *solving* proof-of-work, which is what the
  demos' register step and the e2e harness do on the client side. Verifying a
  proof is pure Ruby and needs neither.
- **`curl` and `jq`**, for the harness and for the demo flow drivers.

`e2e/run.sh` refuses to start with a named prerequisite missing rather than
failing halfway through, so running it is also the fastest way to find out
whether your machine is ready.

## Running things

**One gem.** Each gem has its own bundle:

```bash
cd kiosk-core
bundle install
bundle exec rspec
```

`kiosk-rls-minitest` is the one exception — it is a Minitest harness and runs
`bundle exec rake test`.

**One demo.** Each demo is a standalone Rails app with its own bundle and its
own README. Read that README first: its prerequisites block is *generated* from
the demo's own files, and its "Which of these run in CI" table is *generated*
from the workflow, so both are true rather than remembered. Then:

<!-- runbook-runnable: bin/check-runbook-blocks --run executes this block verbatim -->
```bash
cd kiosk-demo-hoteling
bundle exec rake -T          # what this demo can do
```

`rake demo:setup` **drops and recreates that demo's database** before loading
the schema and seeding — unconditionally, with no prompt. Run the tasks one at a
time: a batched `rake a b c` stops at the first task that exits the process and
says nothing about the ones that never ran.

**The whole wire.** `./e2e/run.sh` builds a throwaway Rails app, installs the
gems by path, runs the generator and the migrations, boots a server, drives a
mock assistant against it over HTTP, validates the live bytes against the
published JSON Schemas, and tears down.

<!-- runbook-runnable: bin/check-runbook-blocks --run executes this block verbatim -->
```bash
./e2e/run.sh
```

**The guards.** `bin/check-*` holds the properties a test suite cannot: that a
shipped README's install snippet resolves, that nothing shipped cites material
that does not ship with it, that no process-spawning construct is reachable from
the code that verifies a proof, that every demo task is either gated in CI or
opted out with a written reason, and about twenty more. They are plain scripts —
run one directly:

<!-- runbook-runnable: bin/check-runbook-blocks --run executes this block verbatim -->
```bash
bin/check-publication-paths
```

Most of them also take `--self-test`, which plants a break of every rule it
holds and fails unless the script goes red on each one. If you change a guard,
run its self-test; if you add a rule to one, add an arm for it.

<!-- runbook-runnable: bin/check-runbook-blocks --run executes this block verbatim -->
```bash
bin/check-publication-paths --self-test
```

## The merge gate

Tests covering the change must be green before merge. For this repository that
means **the touched gem's own suite plus `./e2e/run.sh`**, and the guards that
own whatever you touched. CI (`.github/workflows/ci.yml`) runs all of it — every
gem suite, every gated demo task, the e2e harness, and each guard as its own job
— so a pull request tells you the same thing your laptop does. It is much faster
to find out locally.

Two things CI does *not* do, and they are yours:

- **The changelog.** A significant change — anything that alters behaviour, spec
  text, skill instructions, or a claim this project makes — gets an entry: the
  root `CHANGELOG.md` for a repository-wide change, `<gem>/CHANGELOG.md` for a
  change to that package. **Keep the entries short, always under 200 characters
  and one-two sentences; only keep the essence of the change.** The commit
  message keeps the details. That rule binds every `CHANGELOG.md` here, and
  `bin/check-changelog` holds it on entries that are new against its declared
  baseline commit — the standing backlog is printed as a census and never
  reddens. Tests-only changes, refactors and typos do not qualify. Nothing
  already written is edited: history is append-only, and an entry that turns out
  to be wrong is superseded by a new one that names it.
- **Shared code across demos.** The demos are separate applications, so shared
  code is hand-copied on purpose. `bin/check-demo-copies` declares every file
  that exists in two or more of them and holds the copies in lockstep. If you
  edit one, that check tells you which siblings you also have to edit — and
  fails until you do.

## Style, as this repository actually practises it

- **A comment explains the code, never its history.** So does a document: a
  public artefact describes what *is*. The afterlife of a removed endpoint,
  configuration key or wire element is one short changelog line — not a README
  paragraph, not a "note that X no longer…". A reader arriving today has no
  memory to correct. A *live* caveat that still binds someone is the opposite:
  that is what the document is for.
- **A number in prose is a measurement, and measurements rot.** Prefer the
  command that produces it over the integer it produced. Several guards exist
  because a hand-kept count went quietly false.
- **Commit messages** carry a short area prefix (`spec:`, `demos:`, `guard:`,
  `kiosk-server:`, or the demo's name) and a subject that says what changed and
  why. Small, one-concern commits, please, rather than one pile.

## Licensing

This project is Apache-2.0 (see [LICENSE](LICENSE)). There is no CLA and no
sign-off requirement: under Section 5 of that license, a contribution you
intentionally submit for inclusion is under the same terms, unless you say
otherwise. If you cannot contribute under Apache-2.0, say so in the pull request
before we review it.
