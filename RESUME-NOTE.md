# RESUME NOTE — K-503 (loose `*_flow.rb` scripts at demo top level)

**Branch:** `flow-scripts-0811`. Delete this file in the final commit.

## Convention chosen
`script/` — the stock Rails 8 app directory for non-executable, developer-run
scripts (`bin/` is reserved for executable binstubs). All demo driver scripts
(`*_flow.rb`, `redteam_suite.rb`, `rls_overlay.rb`, `rls_proof.rb`) move from
the demo root to `<demo>/script/`.

## Steps
1. [DONE, committed eda41f0] `git mv` in the seven operator demos:
   atablefor, getgrocery, hoteling, philslist, skooti, stylish, tudu (45 files).
2. [DONE, committed eda41f0] References updated (demo.rake, require_relative,
   `$LOAD_PATH.unshift ../lib`, `../../kiosk-pow-equihash/solve.py`, READMEs,
   initializer comments, skooti bin/ble-unlock + bin/make-qr, kiosk-redteam
   client doc, two kiosk-test-support spec comments).
3. [DONE] Repo-wide sweep: ZERO surviving unprefixed references. Checked
   demo.rake ×7, require_relative, all 8 demo READMEs, before-after.md,
   .github/workflows/ci.yml (goes through rake, no direct paths), deploy/**
   (none), root README + CLAUDE.md (none), autoload_lib ignore lists (unaffected —
   `script/` is not an autoload path), e2e/ (its `*_flow.rb` live in
   `e2e/fixtures/`, a different tree, untouched).
4. [DONE] kiosk-demo-prove has NO top-level scripts — nothing to move.
5. [DONE] Dead-surface scan: every one of the 45 moved scripts is referenced.
6. [in progress] CHANGELOG line + gates: every `demo:` rake task serially
   (port 3001 collision!), zeitwerk:check on all 8 demos (DONE, 8/8 exit 0),
   ci.yml YAML parse (DONE, OK), ./e2e/run.sh.

## Scope guards
- Do NOT restructure `config/initializers/kiosk.rb` or demos' `lib/` (K-502 /
  K-495 / T-052..T-057). Editing a path STRING in a comment or `load` line is OK.
- Unreferenced scripts = D5 finding, report, do not delete.
