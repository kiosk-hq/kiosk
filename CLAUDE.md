# kiosk reference implementation — constitution

This repo is the Kiosk OSS monorepo: core gems (`kiosk-core`, `kiosk-server`,
`kiosk-all`, `kiosk-test-support`), opt-in RLS (`kiosk-rls`, `-rspec`,
`-minitest`), adapters (`kiosk-pay-stripe`, `kiosk-user-idp-devise`), PoW
(`kiosk-pow-equihash` — default, n=168 k=7; `kiosk-pow` — Argon2id legacy;
`kiosk-pow-cuckoo`), security (`kiosk-reputation`, `kiosk-redteam`), eight
demo Rails apps (`kiosk-demo-*` — seven operators plus the `kiosk-demo-prove`
KYC broker), and the `e2e/` harness. Gem table:
`README.md`.

The normative spec lives at https://kiosk.tech (`specification.html`); the
universal agent skill is `skill.md` on the same site.

## The five rules

1. **Authority chain.** The spec (`kiosk.tech/specification.html`) is
   normative. Code and skill conform to the spec; landing/HN/README claim
   only what the code demonstrably does. An ADR may override the spec — then
   the spec must be updated to match.
2. **Conflict rule.** On a conflict with no recorded decision (ADR or a
   ledger `decision`): do NOT pick a side. Record it in the findings ledger
   as `decision-needed` and skip that item.
3. **Scope rule.** Found a problem outside your current task? Record it in
   the findings ledger. Do not fix it inline.
4. **Merge gate.** Tests covering the change must be green before merge; for
   `reference` that means the touched gem's own suite + `e2e/run.sh`.
   **AND `kiosk-test-support`'s SUITE IS A GATE ON ANY RUBY CHANGE ANYWHERE,
   including a demo's (2026-09-24).** «The touched gem's own suite» reads as
   «the gem you edited», and a wave that edits a DEMO runs that demo's task
   list and stops. But that suite walks the WHOLE tracked Ruby corpus — every
   tracked `.rb`, counted on each run and printed in its own failure text — so
   it is the only thing holding
   properties no single gem owns: no parse warning, no dead binding, no dated
   literal, no cross-app require, every demo's skill pin. MEASURED: a
   `rescue nil` in `kiosk-demo-hoteling/lib/tasks/demo.rake` left `result`
   assigned and unread, the demo's own task list was green because the beat
   asserted only that an untouched row was untouched, and CI went red on TWO
   pushed heads with `assigned but unused variable - result` (K-1793). Run it
   whenever any `.rb` in this repository moves.
5. **Changelog rule.** Significant changes — anything altering behavior, spec
   text, skill instructions, or claims — get an entry in the touched repo's
   `CHANGELOG.md` stating the essence and intent of the change, not its
   content. Tests-only changes, refactors, typos do not qualify.
   **THE STRONG RULE (Phil, 2026-09-11), his words. It binds EVERY
   `CHANGELOG.md` in this repository — the root record and every per-gem
   package record alike. There is no second register and no exception; the
   «journal for the root file, release notes for the gems» split this rule
   used to carry is REPEALED:**

   > **Keep the entries short, always under 200 characters and one-two
   > sentences. Only keep the essence of the change. git commit messages will
   > keep the details. In the CHANGELOG, only keep the essence.**

   The details belong in the git commit message and in the ledger row. Nothing
   already written is edited — a changelog is append-only history — so the long
   standing corpus stays as it is, and `bin/check-changelog` (arms CL-8 length,
   CL-9 sentences) holds the rule on entries that are NEW against its declared
   baseline commit, printing the backlog as a census that never reddens.

   **AND THE ENTRY SAYS WHICH VERSION CARRIES IT, NOT ONLY WHEN IT LANDED (Phil,
   2026-09-24).** An entry is grouped by the release that carries it:
   `## [Unreleased]` holds what is not cut yet, and a cut renames it to
   `## [MAJOR.MINOR.PATCH] — YYYY-MM-DD` and opens a fresh empty one above — **a
   PATCH cut getting a section exactly as a MINOR one does**, since a patch is a
   release here and a date cannot say which version has a change. A cut is a TREE
   event: every gem's version moves to the same number, and the root record AND
   EVERY GEM RECORD get the same heading — a package record is the only thing a
   reader who installed the gem has.
   The entries written before the grouping sit below the
   `## Before release sections` heading, unedited and naming no version.
   **`CHANGELOG-RULE.md` at the root is the authority for how** — where a line
   goes, the shape of a section, the order of a cut — and every changelog here
   points at it instead of repeating it. `bin/check-changelog` holds the shape
   (CL-11 heading grammar, CL-12 an open section, CL-13 no ungrouped entry).

## Repo specifics

- Ruby 4.0.1 — what `.github/workflows/ci.yml` installs at every `setup-ruby`
  step but the declared-floor leg, which reads the floor out of a gemspec;
  no toolchain pin is tracked (`mise.toml`, `.mise.toml` and
  `.ruby-version` are gitignored). Per-gem bundles: `cd <gem> && bundle install &&
  bundle exec rspec` (`kiosk-rls-minitest`: `bundle exec rake test`).
- Demos: `bin/rails demo:setup`, then the flow tasks
  (`check:walkthrough`/`shop`/`book`/`rideflow`/`collab`, `check:isolation`,
  `check:redteam`). Postgres required.
- Full e2e: `./e2e/run.sh` (Postgres + jq). CI: `.github/workflows/ci.yml`
  (gems matrix + demos matrix + e2e). A demo task's namespace says what it is:
  `check:` ASSERTS and goes red, `demo:` is one a person runs and reads. Which
  `check:` tasks CI runs — and the recorded reason for each one it does not — is
  enforced by `bin/check-ci-tasks` and published in every demo README's "Which of
  these run in CI" table; adding a `check:` task means adding it to the matrix
  `tasks:` list or to that entry's `ungated:` map, naming it in that README's own
  hand-written task list (the same check asserts presence, never the prose), then
  `bin/check-ci-tasks --write`.
- The demos are separate Rails apps, so shared code is HAND-COPIED.
  `bin/check-demo-copies` (its own CI job) declares every hand-written Ruby file
  that exists in two or more demos — plus `.gitignore` — as `:identical`,
  `:code` (identical modulo comments and whitespace, MAGIC comments excepted:
  those are compared) or `:per_demo`, with a reason; editing one copy of a
  lockstep file means editing all of them, and a NEW duplicate fails the build
  until it is declared. Copy a file between demos → add it to that manifest.
  `:per_demo` says the FILE is not compared; it does not exempt what is inside
  it. Individual methods and constants shared across copies of a `:per_demo`
  path are declared in the same script's `FRAGMENTS` manifest and compared with
  `:code` semantics (T-120), and a unit name appearing in two or more copies of
  a declared path fails the build until it is declared — so copy a METHOD
  between demos → declare it there, or give the second copy its own name.
  A demo's `spec/` and `test/` trees are held one step differently, because the
  duplication there is at UNIT granularity: a path-keyed rule reaches only the
  copies that sit at a relative path two or more of those files share, and
  almost all of them sit at a path unique to their own demo. (Not none — the
  demos that ship `spec/wire_arguments_spec.rb` do share one, and `FRAGMENTS`
  holds it. Saying «none» here was wrong for a day, K-1536.) So the same
  script's `SPEC_UNITS` manifest keys on the UNIT NAME over the whole tracked
  spec corpus, and a helper copied into a second spec file — in another demo or
  in the same one — fails the build until it is declared (K-1536). The FILE is
  held too: a relative path that two or more of those spec files share must be
  declared in `EXTRA_SCANNED`, which is what hands it to the file-level manifest
  and its COPIES entry — without that the unit rule compares the names it knows
  and everything else in the copy is compared against nothing (K-1550). Which rule
  reaches how many copies is COUNTED on every run and printed in the green line;
  read it there rather than restating it here.
  The `db/migrate` copies are ALSO held against the engine's install-generator
  `.rb.tt` templates (rendered with the generator's defaults, byte-matched), so
  editing a template in kiosk-server without regenerating the demos — or
  vice versa — fails the build; known divergences live in `GENERATOR_TEMPLATES`
  as `drift:` records that error the day their copies converge.
  Most of the Rails skeleton (`bin/`, `config/`, `public/`, `Rakefile`,
  `config.ru`, `db/seeds.rb`) is deliberately NOT compared — each demo edits it
  for its own port and host — and that exclusion is recorded, path by path with
  its reason, in the same file's `SKELETON_NOT_COMPARED`; the skeleton paths
  with no per-demo dimension (the T-048 statics, the three error pages,
  `puma.rb`, `environments/{test,production}.rb`) ARE declared in the manifest,
  `:identical` with prove as the stated exception (K-643) — as are `bin/setup`
  and `bin/dev`, which stopped being generator output when K-1315 pointed setup
  at the demo's own `demo:setup`. Beside that manifest, the same script derives
  one thing from the scripts themselves: every `bin/<name>` a demo's `bin/`
  scripts or its README NAME must resolve to an existing, executable file.
- The four `kiosk-demo-*/before-after.md` are a PUBLISHED narrative and every
  fenced block in them DERIVES from something in the same demo, declared in a
  comment above the fence: `<!-- derived: transcript | task: … | from: … |
  abridged: … -->` or `<!-- derived: snippet | from: … | transform: … |
  abridged: … -->`, or `derived: none` with a reason. `bin/check-demo-derivations`
  (its own CI job) then holds every transcript line to a string literal the named
  task actually prints and every snippet line to a line of the file it quotes
  under the declared transformation — membership, never regeneration, so ids and
  dates and wall-clock branches do not flap it. Editing one of those documents,
  or renaming a `puts` in a flow driver or rake task, means running it. Its
  header states what it cannot see; read that before trusting a green run.
- **A migration that has shipped is never edited — a change arrives as a NEW
  file.** `db/migrate/` is not source you can refactor: every file in it is
  already recorded in the `schema_migrations` of every deployed database, and
  `db:migrate` never re-runs a recorded version. So an edit to one reaches
  `db/structure.sql` and every from-zero database — every gate, every laptop —
  and **can never reach a running one**. That is not a hypothetical: `3a834cc0`
  appended `add_column :users, :display_name` to a tudu migration that had
  shipped a month earlier, and the live box answered HTTP 500 on four pages
  while CI stayed green on all of them (K-1074). In the tree the defect stood
  four days — `3a834cc0` (2026-08-23) to `86c89923` (2026-08-27); on the box it
  is STILL OPEN, because a correction reaches a running database only on a
  redeploy, and how long those pages have been 500 is not measurable from this
  side at all. The commit's own comment reasoned itself into it *while citing
  atablefor*, which had made the identical change correctly in a new file — so
  "a careful author will notice" is exactly the control that failed.
  Renumbering counts as editing: `267e67b3` re-emitted the kiosk set under new
  timestamps and every deploy since has ABORTED its migrate step one step in
  (K-1083). Pre-1.0 the set may still be collapsed, and that was the last time
  (T-103, MIGRATION-AND-CONFIG-UPGRADE-POLICY); at 1.0 `db/migrate/` freezes
  and becomes append-only. The gate is `bin/check-migration-replay` (its own
  step in the demos job): it loads each historical `db/structure.sql` since the
  fleet was provisioned, runs `db:migrate` against it, and diffs the catalog
  against the tracked one — the only place in this repo where `db:migrate`
  meets a database that already exists. When it fails, the repair is a new
  migration file, and on the boxes it is `deploy/demo-reset.sh`.
- The gems are meant to be installable, but every consumer here uses `path:`,
  which reads the working tree — so a file missing from `spec.files` is
  invisible locally and fatal from RubyGems. `bin/check-gem-packaging` (its own
  CI job) builds all 14 gems and asserts every tracked file is packaged or
  declared in its `NOT_PACKAGED` manifest with a reason, and that every
  `__dir__`-relative path resolves inside the package. Adding an asset a gem
  reads at runtime means adding it to `spec.files`. Its third rule is about the
  same reader rather than the same bytes: a PACKAGED file that teaches
  installing a Kiosk gem — a `gem "kiosk-…"` line, a `bundle add`, a `gem
  install` — must point at the monorepo README's Install section, which is
  where publication status is stated CANONICALLY, because someone holding the
  built gem has that file and nothing else. Canonically and not solely: the
  kiosk.tech onboarding guide carries a DERIVED copy of that README's claim,
  held to it word for word by `bin/check-onboarding-derivation`'s
  `PUBLICATION_STATUS` rule — a «one place» that a second live page contradicts
  is how a maintainer changes one file on publication day and leaves the other
  saying no gem is published (K-1381). The pointer is DERIVED from that README (the
  canonical line's `github:` slug plus its own heading), so the day the gems are
  published the rule fails and asks to be restated rather than passing quietly;
  a mention that is prose about the resolver rather than an instruction is
  declared in `INSTALL_MENTION_ONLY` with its reason, and goes stale loudly.
- Version parity is a build gate, not prose. The spec (§14.1) binds the
  protocol, this implementation and the skill to one MAJOR.MINOR — read it from
  `kiosk-core/lib/kiosk/protocol.rb`'s `API_VERSION`, or from the guard's own
  first line of output, never from this sentence (it was a MINOR stale for the
  whole of 0.4, K-932) — so `bin/check-version-parity` (its own CI job) asserts every gemspec
  version, every `kiosk-*` inter-gem constraint (`~> <series>.0`) and every
  pinned `skill_url`'s version share that series with
  `Kiosk::Protocol::API_VERSION`. PATCH stays free per gem and per skill cut.
  Bumping the protocol series means bumping the gems in the same change.
- Inline `TODO`/`FIXME` must state a concrete rationale, not a bare marker.
