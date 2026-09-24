# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# Event-stream listener pin guard, wired into the gem whose file it protects
# (T-169). Same shape as kiosk-pow-equihash's solver_pin_spec, and for the same
# reason.
#
# listen.py ships here, but its bytes are load-bearing OUTSIDE this gem: the
# published skill tells an assistant to verify the file's SHA-256 against a
# pinned value and REFUSE to execute it on a mismatch. Editing listen.py
# without republishing kiosk.tech/events/listen-vX.Y.Z.py therefore does not
# fail loudly — assistants quietly go back to polling, which still works, so
# the operator's only symptom is that the stream they built stopped being used.
#
# The merge gate for a change to this file is "the touched gem's own suite", so
# the guard has to live in the touched gem's own suite. The checks themselves
# are in bin/check-listener-pin (they span two repos' copies and are also run
# standalone by the scheduled CI job that probes the live site); this example is
# the hook that makes `bundle exec rspec` here run them.
RSpec.describe "event-stream listener pin" do
  # spec/ -> kiosk-server/ -> the monorepo root
  script = File.expand_path("../../bin/check-listener-pin", __dir__)

  it "matches the sha256 the published cut carries" do
    skip "bin/check-listener-pin not present (gem-only checkout)" unless File.exist?(script)

    out, status = Open3.capture2e(RbConfig.ruby, script, "--offline")

    expect(status).to be_success,
                      "bin/check-listener-pin --offline failed — listen.py and the published " \
                      "cut have drifted:\n\n#{out}"
  end
end
