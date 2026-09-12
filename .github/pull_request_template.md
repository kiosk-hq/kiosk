## What changes, and why

<!-- One paragraph. What was wrong before, and what this makes true instead. -->

## The gate

- [ ] The touched gem's own suite is green (`cd <gem> && bundle exec rspec`; `bundle exec rake test` for `kiosk-rls-minitest`)
- [ ] `./e2e/run.sh` is green
- [ ] The `bin/check-*` guards that own what I touched are green — and if I changed a guard, its `--self-test` too
- [ ] A `CHANGELOG.md` entry, if this alters behaviour, spec text, skill instructions or a claim (per-gem file = release notes; the repository-root file = the dated journal). Tests-only changes, refactors and typos do not need one.

<!-- Say which commands you actually ran. A command you did not run is not verified. -->

## Anything a reviewer should know

<!-- A decision you were unsure about, a trade-off, something you could not test. -->
