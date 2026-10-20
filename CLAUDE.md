# kiosk reference implementation — constitution

This repo is the Kiosk OSS monorepo: core gems (`kiosk-core`, `kiosk-server`,
`kiosk-all`, `kiosk-test-support`), opt-in RLS (`kiosk-rls`, `-rspec`,
`-minitest`), adapters (`kiosk-pay-stripe`, `kiosk-kyc-prove`,
`kiosk-user-idp-devise`), PoW (`kiosk-pow` is the base of `kiosk-pow-equihash`,
the default, `kiosk-pow-cuckoo` and `kiosk-pow-argon2id`), security (`kiosk-reputation`,
`kiosk-redteam`), eight demo Rails apps (`kiosk-demo-*` — seven operators plus the `kiosk-demo-prove`
KYC broker), and the `e2e/` harness. Gem table: `README.md`.

The normative spec is `specification.html` at https://kiosk.tech; the agent
skill is `skill.md` on the same site.

## The five rules

1. **Authority chain.** The spec is normative. Code and skill conform to it.
   Landing pages, posts and READMEs claim only what the code does. An ADR may
   override the spec; then update the spec.
2. **Conflict rule.** On a conflict with no recorded decision, do not pick a
   side. Ask the question on its task in the task store and skip the item.
3. **Scope rule.** A problem outside your task goes into the task store, not
   into an inline fix.
4. **Merge gate.** Tests that cover the change are green before merge: the
   touched gem's suite plus `e2e/run.sh`. When any `.rb` file in this
   repository changes, also run `kiosk-test-support`'s suite. It reads every
   tracked Ruby file and holds what no single gem owns: no parse warning, no
   unused variable, no dated literal, no cross-app require, every skill pin.
5. **Changelog rule.** A change to behaviour, spec text, skill instructions or
   claims gets an entry in the touched `CHANGELOG.md` (the root record or a
   gem's record). Tests-only changes, refactors and typo fixes get none.
   - One or two sentences, under 200 characters, the essence only. Details go
     in the commit message.
   - New entries go under `## [Unreleased]`. A cut renames it to
     `## [MAJOR.MINOR.PATCH] — YYYY-MM-DD` and opens a new empty one above. A
     PATCH cut gets a section too.
   - A cut moves every gem to the same version. The root record and every gem
     record get the same heading.
   - Never edit a written entry.
   - `CHANGELOG-RULE.md` at the root is the procedure.

## Repo specifics

- Ruby 4.0.1, as `.github/workflows/ci.yml` installs it; every gemspec
  declares `>= 4.0`. No toolchain pin is tracked. Per gem:
  `cd <gem> && bundle install && bundle exec rspec`
  (`kiosk-rls-minitest`: `bundle exec rake test`).
- Demos: `bin/rails db:reset` prepares one, `bin/rails test` tests it
  (hoteling: `bundle exec rspec`). CI also runs its
  `kiosk-redteam/suites/<demo>.rb` against a started server. Postgres is required.
- Lint: `bin/lint` from the root bundle runs RuboCop (default cops plus the
  Rails, Minitest and RSpec Rails plugins), bundler-audit over every tracked
  `Gemfile.lock`, and Brakeman over every demo. CI's `lint` job runs it. Fix
  the offense; do not disable the cop. A rare inline `# rubocop:disable`
  states its reason after `--`. A Brakeman false positive goes into that app's
  `config/brakeman.ignore` with a note.
- Full e2e: `./e2e/run.sh` (Postgres and jq). CI: `.github/workflows/ci.yml`.
- A demo task's namespace says what it is: a `check:` task asserts and fails,
  a `demo:` task is for a person to run and read. When you add a `check:`
  task, add it to the CI matrix `tasks:` list or to that entry's `ungated:`
  map, and to the demo README's task list and "Which of these run in CI"
  table.
- The demos are separate Rails apps, so shared code is copied by hand.
  `bin/check-demo-copies` holds every copy:
  - Copy a file between demos: declare it in the manifest (`:identical`,
    `:code` or `:per_demo`, with a reason). Edit every copy of a lockstep
    file together.
  - Copy a method or constant between `:per_demo` files: declare it in
    `FRAGMENTS`, or give the second copy its own name.
  - Copy a helper between spec or test files: declare it in `SPEC_UNITS`. A
    spec path that two demos share goes in `EXTRA_SCANNED`.
  - A new install-generator `.rb.tt` template: declare it in
    `GENERATOR_TEMPLATES`.
  - A skeleton file a demo edits for its port and host: record it in
    `SKELETON_NOT_COMPARED` with its reason.
- Every fenced block in a `kiosk-demo-*/before-after.md` derives from its
  demo, declared above the fence: `<!-- derived: generator | from: … -->`.
  When you edit one of these documents, run it.
- Never edit a shipped migration's code; a change arrives as a new file. A
  comment in it may be corrected. Renumbering is editing. Before 1.0 a demo's migrations may be collapsed into a fresh
  install only together with rebuilding every deployed database
  (`deploy/CHECKLIST.md` §7b). At 1.0 `db/migrate/` becomes append-only.
- Every consumer here uses `path:`, which reads the working tree. When a gem
  reads a new asset at runtime, add it to `spec.files`.
- Version parity (spec §14.1) binds the protocol, this implementation and the
  skill: before 1.0 to one MAJOR.MINOR.PATCH, from 1.0 to one MAJOR.MINOR. The
  number is `kiosk-core/lib/kiosk/protocol.rb`'s `API_VERSION`. Every
  gemspec, every tracked lockfile and every pinned `skill_url` follow it.
  `MIN_CLIENT` is the oldest skill cut the release works with: the same
  MAJOR.MINOR, no newer. Every `kiosk-*` inter-gem constraint is
  `~> MAJOR.MINOR.0`. A skill cut moves the gems, and a gem release moves the
  skill, in the same change.
- An inline `TODO`/`FIXME` states a concrete reason.
