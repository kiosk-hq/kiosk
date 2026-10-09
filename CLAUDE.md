# kiosk reference implementation — constitution

This repo is the Kiosk OSS monorepo: core gems (`kiosk-core`, `kiosk-server`,
`kiosk-all`, `kiosk-test-support`), opt-in RLS (`kiosk-rls`, `-rspec`,
`-minitest`), adapters (`kiosk-pay-stripe`, `kiosk-kyc-prove`, `kiosk-user-idp-devise`), PoW
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
   standing corpus stays as it is.

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
   points at it instead of repeating it.

## Repo specifics

- Ruby 4.0.1 — what `.github/workflows/ci.yml` installs at every `setup-ruby`
  step but the declared-floor leg, which reads the floor out of a gemspec;
  no toolchain pin is tracked (`mise.toml`, `.mise.toml` and
  `.ruby-version` are gitignored). Per-gem bundles: `cd <gem> && bundle install &&
  bundle exec rspec` (`kiosk-rls-minitest`: `bundle exec rake test`).
- Demos: `bin/rails db:reset` prepares one, `bin/rails test` (hoteling and
  kiosk-demo-prove: `bundle exec rspec`) tests it, and CI also runs its
  `script/redteam_suite.rb` against a started server. Postgres required.
- Full e2e: `./e2e/run.sh` (Postgres + jq). CI: `.github/workflows/ci.yml`
  (gems matrix + demos matrix + e2e). A demo task's namespace says what it is:
  `check:` ASSERTS and goes red, `demo:` is one a person runs and reads. Which
  `check:` tasks CI runs — and the recorded reason for each one it does not — is
  published in every demo README's "Which of these run in CI" table; adding a
  `check:` task means adding it to the matrix `tasks:` list or to that entry's
  `ungated:` map, and to that README's task list and table.
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
  and everything else in the copy is compared against nothing (K-1550).
  The `db/migrate` copies are ALSO held against the engine's install-generator
  `.rb.tt` templates (rendered with the generator's defaults, byte-matched), so
  editing a template in kiosk-server without regenerating the demos — or
  vice versa — fails the build. Every template is declared in `GENERATOR_TEMPLATES`
  either `emits:` (compared in all seven) or `not_compared:` with its reason;
  there is no third state, so a divergence is fixed rather than recorded.
  Most of the Rails skeleton (`bin/`, `config/`, `public/`, `Rakefile`,
  `config.ru`, `db/seeds.rb`) is deliberately NOT compared — each demo edits it
  for its own port and host — and that exclusion is recorded, path by path with
  its reason, in the same file's `SKELETON_NOT_COMPARED`; the skeleton paths
  with no per-demo dimension (the T-048 statics, the three error pages,
  `puma.rb`, `environments/{test,production}.rb`) ARE declared in the manifest,
  `:identical` with prove as the stated exception (K-643) — as are `bin/setup`
  and `bin/dev`. Beside that manifest, the same script derives
  one thing from the scripts themselves: every `bin/<name>` a demo's `bin/`
  scripts or its README NAME must resolve to an existing, executable file.
- The four `kiosk-demo-*/before-after.md` are a PUBLISHED narrative and every
  fenced block in them DERIVES from something in the same demo, declared in a
  comment above the fence: `<!-- derived: generator | from: … -->`. Editing one of those
  documents means running it.
- **A migration that has shipped is never edited — a change arrives as a NEW
  file.** `db:migrate` never re-runs a recorded version, so an edit reaches
  `db/schema.rb` and every from-zero database — every gate, every laptop —
  and never a running one. Renumbering counts as editing. Before 1.0 a demo's
  whole set may be collapsed into a fresh install, and only together with
  rebuilding every deployed database (`deploy/CHECKLIST.md` §7b); at 1.0
  `db/migrate/` freezes and becomes append-only.
- The gems are meant to be installable, but every consumer here uses `path:`,
  which reads the working tree — so a file missing from `spec.files` is
  invisible locally and fatal from RubyGems. Adding an asset a gem reads at
  runtime means adding it to `spec.files`.
- Version parity: the spec (§14.1) binds the
  protocol, this implementation and the skill: before 1.0 to one
  MAJOR.MINOR.PATCH, from 1.0 to one MAJOR.MINOR. Read the number from
  `kiosk-core/lib/kiosk/protocol.rb`'s `API_VERSION`, never from this sentence.
  Every gemspec, `MIN_CLIENT`, every tracked lockfile and every pinned
  `skill_url` follow it, and every `kiosk-*` inter-gem constraint is
  `~> MAJOR.MINOR.0`. A skill cut moves the gems, and a
  gem release moves the skill, in the same change.
- Inline `TODO`/`FIXME` must state a concrete rationale, not a bare marker.
