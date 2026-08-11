# RESUME NOTE — gemfiles-0811 (T-060; delete in the final commit)

Task: gem-packaging blocker + 14-gemspec sweep + a CI guard + the K-580 gemspec
description half.

## Verified facts (gem build + gem unpack, ruby 4.0.1 / rubygems 4.0.3)

- `gem build` does NOT chdir into the gemspec's directory — the `Dir.glob`
  in every gemspec resolves against CWD. Building from the repo root fails
  (`["LICENSE.txt"] are not files`). Any checker must chdir to the gem dir.
- RubyGems drops directory entries from `spec.files` at build time.
- After the fixes, the ONLY tracked-but-unpackaged files across all 14 gems are
  dev scaffolding: `.gitignore` `.rspec` `Gemfile` `Gemfile.lock` `Rakefile`
  `*.gemspec` `spec/**` `test/**`. Re-verified by unpacking, not reasoned about.
- `__dir__`-relative path literals in gem lib code (5 sites, all now guarded):
  kiosk-server request_validation.rb:39 -> schemas/pow.schema.json OK;
  install_generator.rb:38 -> templates/ OK; {device_verify,assistants}_controller
  -> ../../../app/views (was BROKEN, fixed); kiosk-redteam client.rb:282 ->
  ../../../../kiosk-pow-equihash/solve.py ESCAPES THE GEM ROOT — declared in
  OUT_OF_GEM, needs Phil's decision (dep + public API).

## Progress

- [x] survey
- [x] fix kiosk-server spec.files + description  (26adcef)
- [x] fix kiosk-pow-equihash / kiosk-pow-cuckoo gemspec traps  (399965d)
- [x] bin/check-gem-packaging + CI job  (5981cc6)
- [x] watched-red proof — 4 paths (original omission; `*.rb` glob; stale
      OUT_OF_GEM; unreadable `__dir__` shape). All reverted, tree green.
- [x] kiosk-all description + README (same staleness as kiosk-server's)
- [x] CHANGELOG line
- [ ] final gates re-run, then DELETE THIS FILE
