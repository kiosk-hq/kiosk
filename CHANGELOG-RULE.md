# How to write a CHANGELOG entry here

This repository keeps a changelog at the root and one inside every gem, and they
share one set of rules. Read this before adding a line. `bin/check-changelog`
holds the parts a script can hold and names the arm that failed; its header says
what it cannot see.

## The entry

Phil's rule, in his words (2026-09-11):

> Keep the entries short, always under 200 characters and one-two sentences.
> Only keep the essence of the change. git commit messages will keep the
> details. In the CHANGELOG, only keep the essence.

It binds every `CHANGELOG.md` here — the root record and every per-gem package
record alike. State the essence of the change and what it is for, never its
content: the commit message and the ledger row are where the details go.

Every top-level entry opens with its ISO date, `- YYYY-MM-DD: ` (arm CL-7).

## Where the line goes

- **The repository record** is `CHANGELOG.md` at the root: one entry per
  significant change anywhere here — engine, gem, demo, deploy runbook. This is
  the target of the one-line rule, always.
- **A gem record** is `<gem>/CHANGELOG.md`, and every gem directory has one:
  each gemspec publishes that file inside the package, so it is what a reader
  who installed the gem and never saw this repository has. A change to a gem's
  published surface gets its release note there as well.
- **A demo record** is optional and declared, in the `COURTESY` manifest of
  `bin/check-changelog`, with the reason it exists. It is never the target of
  the one-line rule.

## The version is in the heading, and a PATCH is a release

Entries are grouped by the release that carries them, so a reader can answer
«which version has this change?» A date cannot answer it. **A MINOR cut and a
PATCH cut each get their own section — that is the point of the rule.**

    ## [Unreleased]               new entries go here, newest first

    ## [0.4.1] — 2026-09-24       a cut renames [Unreleased]; a fresh empty one opens above it

    ## Before release sections    the entries written before this file grouped them

Three shapes, and the check holds them:

1. Every record carries exactly one `## [Unreleased]`, and it is the first
   section in the file. A new entry goes INSIDE it — an entry above the first
   section belongs to no release and is refused (arms CL-12, CL-13).
2. A version section names the version AND the date it was cut,
   `## [MAJOR.MINOR.PATCH] — YYYY-MM-DD`. A section named for a MAJOR.MINOR
   alone, or carrying no date, is refused (arm CL-11) — a two-number heading is
   exactly the thing this rule exists to stop.
3. `## Before release sections` is the one heading that is NOT a release. It
   holds the entries written before this file grouped them: they are not a cut,
   they are not `[Unreleased]` either — most of them are long published — and
   they are never edited.

**Where the number comes from, so a changelog never invents one.** MAJOR.MINOR
is fixed by version parity: the protocol, this implementation and the published
skill share it, and `bin/check-version-parity` holds that. PATCH is the cut's
own. A changelog heading only ever REPORTS a version that the tree already
carries.

**A cut here is a tree event.** The gems move together: a release sets every
gem's version to the same MAJOR.MINOR.PATCH, the root record names it, and every
gem record with entries under `[Unreleased]` gets that same heading and date. A
single gem MAY take a patch of its own — version parity binds MAJOR.MINOR only —
and then only that gem's record gets the section, while the root record's entry
waits in `[Unreleased]` for the next tree cut.

The order of one cut, and it is the order that keeps the heading true:

1. Bump the version in each `lib/**/version.rb` the cut covers, then run
   `bin/check-version-parity`.
2. Rename `## [Unreleased]` to `## [X.Y.Z] — <the date it was cut>` in the root
   record and in every gem record that has entries under it, and open a fresh
   empty `## [Unreleased]` above each.
3. `bin/check-changelog` green, plus the touched gems' own suites and
   `e2e/run.sh`, before the merge.

## Nothing already written is edited

History is append-only. An entry that has turned out to be wrong is superseded
by a NEW entry that says so and names it, never rewritten. The length and
sentence arms read only entries that are new against the check's declared
baseline commit, so the standing backlog is counted in every run and failed by
nothing — which is why it is safe for the rule to be strict about what arrives
next.
