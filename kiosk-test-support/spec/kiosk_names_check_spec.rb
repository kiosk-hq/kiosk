# frozen_string_literal: true

# `bin/check-kiosk-names` runs in CI (T-068 slice 3; the rule is spec §8.1 / §8.3).
#
# The check itself is a standalone script — no Rails, no database, a second to
# run — and its three assertions are described in its own header. This spec is
# how it reaches CI: kiosk-test-support is in the gems matrix, so running the
# script from here gates every push without a workflow of its own.
#
# It is also the check's own non-vacuity floor. The script's (i) reads the
# engine's `routes do` block and the mixin's RESERVED_NAMES out of two files as
# TEXT; if either constant is renamed or moved, a naive script would find
# nothing on both sides, compare empty to empty and pass. The script errors on
# an unreadable side, and the example below asserts it still sees a real fleet
# — the same defence descriptor_cross_reference_spec.rb carries for the same
# reason.
RSpec.describe "bin/check-kiosk-names" do
  monorepo_root = File.expand_path("../..", __dir__) # spec/ -> kiosk-test-support/ -> reference/
  script        = File.join(monorepo_root, "bin", "check-kiosk-names")

  it "is executable" do
    expect(File.executable?(script)).to be(true), "#{script} is not executable"
  end

  it "passes over the whole fleet" do
    output = `#{script} 2>&1`
    status = $?
    expect(status.exitstatus).to eq(0), output
    expect(output).to include("check-kiosk-names: OK")
  end

  it "actually sees the fleet and the reserved plane (the check is not vacuous)" do
    output = `#{script} --list 2>&1`
    verbs = output[/OK — (\d+) verbs across (\d+) origins/, 1].to_i
    origins = output[/OK — \d+ verbs across (\d+) origins/, 1].to_i
    reserved = output[/(\d+) reserved names/, 1].to_i

    expect(verbs).to be >= 50,
                     "the check resolved only #{verbs} verbs — it has stopped reading the " \
                     "handler controllers:\n#{output}"
    expect(origins).to be >= 8,
                       "the check found only #{origins} origins:\n#{output}"
    expect(reserved).to be >= 5,
                        "the check found only #{reserved} reserved names — the engine's route " \
                        "table or RESERVED_NAMES has moved somewhere it does not read:\n#{output}"
  end
end
