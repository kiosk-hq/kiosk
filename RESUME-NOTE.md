# RESUME-NOTE (T-060) — gemdocs-0811 worktree

Fix agent scope: K-580, K-633, K-634, K-635, K-636.
Owned files: the 14 non-demo `*.gemspec` + gems' `README.md`/`CHANGELOG.md`.
NOT owned: `kiosk-server/lib/**` (parallel agent), demos (parallel agent).

## Status
- [ ] K-580 milestone-label de-versioning sweep
- [ ] K-633 kiosk-pow-equihash.gemspec description/homepage/metadata
- [ ] K-634 missing CHANGELOGs (equihash, redteam) + drop fail-open
- [ ] K-635 dead `](../sibling-gem)` links
- [ ] K-636 kiosk-pay-stripe description under-states SetupIntent half

## Gates to run at the end
bin/check-gem-packaging · bin/check-ci-tasks · bin/check-demo-copies
gem build for touched gemspecs; bundle exec rspec per touched gem.
Do NOT run e2e/run.sh.

Delete this file in the final commit.
