# RESUME NOTE — gemfiles-0811 (T-060; delete in the final commit)

Task: gem-packaging blocker + 14-gemspec sweep + a CI guard + the K-580 gemspec
description half.

## Verified facts (gem build + gem unpack, ruby 4.0.1 / rubygems 4.0.3)

- `gem build` does NOT chdir into the gemspec's directory — the `Dir.glob`
  in every gemspec resolves against CWD. Building from the repo root fails
  (`["LICENSE.txt"] are not files`). Any checker must chdir to the gem dir.
- RubyGems drops directory entries from `spec.files` at build time, so
  `Dir.glob("lib/**/*")` (68 entries, 8 of them directories) packages 60 files.
- The ONLY tracked-but-unpackaged runtime files across all 14 gems:
  - kiosk-server: `app/views/kiosk/server/{assistants/show,device_verify/show,
    device_verify/decided}.html.erb`  ← THE BLOCKER
  - kiosk-pow-equihash: `bench/README.md`, `bench/bench.py` (the shipped README
    links `bench/README.md` twice as the evidence for the 168/7 default)
  Everything else is dev scaffolding (.gitignore/.rspec/Gemfile/Gemfile.lock/
  Rakefile/the gemspec/spec/**/test/**).
- `lib/generators/**/*.tt` ARE packaged (the glob is `lib/**/*`, not `*.rb`).
- `lib/kiosk/server/schemas/pow.schema.json` IS packaged.
- kiosk-pow `solve.py`+`requirements.txt`, kiosk-pow-cuckoo `solve_cuckoo.py`+
  `requirements.txt`, kiosk-pow-equihash `solve.py` ARE packaged.
- `__dir__`-relative path literals in gem lib code (4 sites):
  - kiosk-server request_validation.rb:39 -> schemas/pow.schema.json  OK
  - kiosk-server install_generator.rb:38  -> templates/               OK
  - kiosk-server {device_verify,assistants}_controller -> ../../../app/views  BROKEN (fixed)
  - kiosk-redteam client.rb:282 -> ../../../../kiosk-pow-equihash/solve.py
    ESCAPES THE GEM ROOT — K-candidate, needs a decision (dep + public API).

## Progress

- [x] survey
- [ ] fix kiosk-server spec.files + description
- [ ] fix kiosk-pow-equihash / kiosk-pow-cuckoo gemspec nits
- [ ] bin/check-gem-packaging + CI job
- [ ] watched-red proof
- [ ] CHANGELOG line
