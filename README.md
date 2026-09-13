# Kiosk — OSS reference implementation

Apache-2.0 monorepo for [Kiosk](https://kiosk.tech) — the framework that turns a Postgres-backed business app into an AI-assistant surface (REST endpoint, multi-assistant identity per user, app-layer-authorized data plane with opt-in Postgres RLS defense-in-depth, AP2 mandate trail). Where this is heading: [ROADMAP.md](ROADMAP.md).

## Install

**No Kiosk gem is on RubyGems.** MEASURED 2026-09-06: every gem name in the
tables below answers HTTP 404 from `https://rubygems.org/api/v1/gems/<name>.json`
against a control of `rails` → HTTP 200; this repository carries no release tag,
and no gemspec sets `allowed_push_host`. So a bare `gem "kiosk-all"`, and
`bundle add` of any of these names, do **not** resolve today — **git is the only
install that works.** This section is where publication status is stated
**canonically** — the one place either published repository decides it — and
every install snippet elsewhere points here instead of restating it.

One sentence is copied rather than pointed at, deliberately: the onboarding
guide on kiosk.tech carries the bolded claim above and a link back to this
section, because a reader deciding whether to start an integration should not
have to leave the page to find out the gems are not published. That copy is
DERIVED and not remembered — `bin/check-onboarding-derivation`'s
`PUBLICATION_STATUS` rule reads the claim out of this file and fails until the
page carries it word for word, so rewording it here reddens the page instead of
leaving a live page saying something this repository no longer says.

The canonical install is one line — the meta-gem, from git:

```ruby
# Gemfile
gem "kiosk-all", github: "kiosk-hq/kiosk"
```

<!-- runbook-foreign: these three lines are pasted into the READER's Rails app, not run here -->
```bash
bundle install
bin/rails generate kiosk:install   # the initializer + the kiosk migrations
bin/rails db:migrate
```

`kiosk-all` is `kiosk-core` + `kiosk-server` — the data plane, and nothing else.
The RLS backstop, the PoW backends and the IdP/PSP adapters are deliberately
separate gems you add per stack, each from the same source; `kiosk-all/README.md`
says which and why. When the gems are published this section is where the
`github:` qualifier comes off, and the snippets that point here inherit it.

### What an adopting app needs before that line

| Requirement | Why, and what it rules out |
|---|---|
| **Rails `~> 8.1`** | `kiosk-server` declares `railties`, `actionpack`, `activerecord` and `activesupport` at `~> 8.1`, and it is the only gemspec that names Rails at all. **That excludes Rails 7.x and 8.0.x** — bundler will refuse to resolve against an app on either, so this is a precondition and not a footnote. Older Rails lines are untested here, so they are not claimed; widening the floor means adding a CI leg first. |
| **Ruby `>= 3.2.0`** | Every gemspec declares this floor, and CI exercises **both ends** of the range: one leg on the declared floor, read out of a gemspec at job time, and one on the newest release the demos run. The floor is a tested number rather than an asserted one. |
| **PostgreSQL** | The kiosk schema, the identity tables and the optional RLS backstop are Postgres. No other database is supported. |
| **An existing account model** | `c.user_model` names it, and `c.user_id_type` must match its primary key. Kiosk adds an assistant identity beside your users; it does not replace them. |

No toolchain pin ships in this repository, and that is a decision rather than an
omission: `.ruby-version`, `mise.toml` and `.mise.toml` are gitignored so each
developer manages their own (`kiosk-demo-getgrocery/mise.toml.example` is the
tracked template). The range above is the contract, both ends of it are on the
merge gate, and that is worth more to a contributor than one pinned patch
release a version manager may or may not honour.

### Inside this repository it is `path:`, and that form does not travel

Every Gemfile here consumes its siblings by `path:` — `gem "kiosk-server",
path: "../kiosk-server"` — which serves the working tree rather than a built
package. That is deliberate: it is how a change across gems is tested end to
end. It is also a blind spot, because nothing resolving by `path:` can tell a
file that EXISTS from a file that is PACKAGED, which is why
`bin/check-gem-packaging` exists (below). Do not copy the `path:` form into an
app outside this repository.

The step-by-step operator walkthrough — install through a served wire, with a
worked verb — is [kiosk.tech/onboarding.html](https://kiosk.tech/onboarding.html).

## Layout

**The gem tables and the demo table are scored on DIFFERENT axes, so their values
are not comparable and the columns are named apart below.** The gems carry **API
stability**: `alpha` is pre-v1.0 — the surface may still change between releases —
which is the same thing each gem's own README says about itself. The demos carry
**deployment**: `active` means the demo is gated on every CI run and live at its
own subdomain. A demo being `active` says nothing about how
settled the `alpha` engine underneath it is.

### Core framework

| Gem | Purpose | API stability |
|---|---|---|
| `kiosk-core` | Value types, abstract bases, GUC constants, configuration. No Rails dep. | alpha |
| `kiosk-rls` | Opt-in RLS DSL + migration helpers (`rake kiosk:rls:{show,check}` planned, lands in a follow-up) | alpha |
| `kiosk-server` | Rails engine, routes, kiosk-pop auth surface, executor | alpha |
| `kiosk-all` | Meta-gem; `bundle add kiosk-all` installs core + server — **once the gems are published**; today it is one `github:` line, see [Install](#install) | alpha |
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

**`e2e/` is not in that table, because it is not a ninth provider.** It is the
end-to-end test harness — fixtures, a stub PSP and the AI-assistant pay flow —
so it serves no vertical and deploys nowhere. It runs as a CI gate
(`./e2e/run.sh`) and nothing else.

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

**[CONTRIBUTING.md](CONTRIBUTING.md)** is the whole of it: how to run one gem,
one demo, the end-to-end harness and the `bin/check-*` guards; what the merge
gate is; and what this repository expects of a changelog entry and a comment.
**A security flaw goes through a GitHub issue — read
[SECURITY.md](SECURITY.md) first**, for which repository takes it and for the
fact that filing one is public disclosure.

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

## The two development keypairs this repo tracks on purpose

`kiosk-demo-skooti/config/dev_unlock_key.pem` (Ed25519) and
`kiosk-demo-prove/config/dev_prove_key.pem` (RSA) are private keys, they are
committed, and that is deliberate. Read the header of either file: it says what
the key is for, that it is world-readable, and that it must never sign
anything real. Both applications enforce that rather than asking — production
refuses to boot without an explicit key in the environment, and refuses again
if the key it is given is the shipped one, compared on the public half in DER
so a re-serialised copy cannot slip past.

The Ed25519 one cannot be generated per machine: it is a KNOWN-ANSWER VECTOR.
Its public half and one signature are reproduced in the lock firmware, in the C
host test that firmware ships with, and in the demo's own known-answer test, and
the crosscheck target signs a live message with the private half for the C
verifier to check. A per-machine key turns all of that red on a fresh clone.

**Do not read this as licence to commit a key.** A scanner pointed at this repo
will flag both files, and that is the correct behaviour — which is why
`.github/secret_scanning.yml` names exactly these two paths and nothing else.
`bin/check-publication-paths` fails on any OTHER tracked private key, and on
either of these two if it ever loses its do-not-use banner; it re-proves that
detector against a freshly minted key on every run, so it cannot rot into a
gate that quietly matches nothing. And note the part that no later commit
repairs: this project does not rewrite published history, so a key that reaches
a pushed commit stays reachable in that history whatever a subsequent commit
deletes. Generate at setup or read from the environment; if a fixed vector is
genuinely unavoidable, declare it in that script with the reason.

## License

Apache-2.0 for every gem in this repo. See each gem's `LICENSE.txt`.

Commercial gems (regional PSPs, enterprise-IdP tiers) are planned to live in separate repos under the `kiosk-hq` org, outside this Apache-2.0 monorepo. None exist yet.

## Links

- [kiosk.tech](https://kiosk.tech) — landing page + AI-assistant skill
- [kiosk.tech/skill.md](https://kiosk.tech/skill.md) — universal AI-assistant skill
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
