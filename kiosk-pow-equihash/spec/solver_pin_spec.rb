# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# Solver pin guard, wired into the gem whose file it protects (K-528).
#
# solve.py ships here, but its bytes are load-bearing OUTSIDE this gem: the
# published skill tells every assistant to verify the file's SHA-256 against a
# pinned value and REFUSE to execute it on a mismatch. Editing solve.py without
# republishing kiosk.tech/pow/solve.py and re-cutting the skill therefore does
# not fail loudly — it silently stops every registration that has to pay a toll.
#
# The merge gate for a change to this file is "the touched gem's own suite", so
# the guard has to live in the touched gem's own suite. The checks themselves
# are in bin/check-solver-pin (they span three repos' worth of copies and are
# also run standalone by the scheduled CI job that probes the live site); this
# example is the hook that makes `bundle exec rspec` here run them.
RSpec.describe "Equihash solver pin" do
  # spec/ -> kiosk-pow-equihash/ -> the monorepo root
  script = File.expand_path("../../bin/check-solver-pin", __dir__)

  it "matches the sha256 and URL the published skill pins" do
    skip "bin/check-solver-pin not present (gem-only checkout)" unless File.exist?(script)

    out, status = Open3.capture2e(RbConfig.ruby, script, "--offline")

    expect(status).to be_success,
                      "bin/check-solver-pin --offline failed — solve.py, the 403 hint URL and " \
                      "the published pin have drifted:\n\n#{out}"
  end
end
