# frozen_string_literal: true

# The comparison table's LEVER must be this README's own two numbers divided
# (K-956).
#
# `Lever (solve/verify)` is the economic argument for a metered toll — ADR-0007
# prices abuse rather than walling it out, and the lever IS the price. It read
# `millions×` for months while the same file's benchmark table, three sections
# later, recorded ~9.6 s of solve against ~18 ms of verify: ~530×, off by a
# factor of about two thousand. Nothing caught it because nothing could: the
# number was a claim in a table with no arithmetic behind it, and the two
# measurements it should have been derived from live in different sections
# written at different times.
#
# So this derives it. Both operands are parsed out of the README itself, which
# means a retune that moves the solve time (168/7 replaced 192/7 once already)
# fails here until the lever moves with it, and a faster native verifier does
# the same. It asserts an ORDER OF MAGNITUDE, not a digit — the operands are a
# p50 and a median measured on one laptop, so pinning `533` would be pinning
# noise and would turn every re-measurement into a test edit.
RSpec.describe "the README's solve/verify lever" do
  readme = File.read(File.expand_path("../README.md", __dir__))

  it "states a lever that equals the README's own solve ÷ verify" do
    lever = readme[/^\| Lever \(solve\/verify\).*$/]
    expect(lever).not_to be_nil, "the comparison table has no `Lever (solve/verify)` row"

    claimed = lever[/~?([\d,]+)×\*?\*?\s*\(/, 1] ||
              lever[/\*\*~?([\d,]+)×\*\*/, 1]
    expect(claimed).not_to be_nil,
                          "the lever row states no numeric ratio: #{lever.strip.inspect}. " \
                          "A word (\"millions×\") is not a measurement — state the number this " \
                          "README's own benchmarks give, or state that it is unbenched."
    claimed = claimed.delete(",").to_i

    # p50 solve at the SHIPPED default, from the performance table.
    solve_s = readme[/\*\*n=168, k=7 \(default\)\*\*\s*\|\s*~?([\d.]+) s/, 1]
    expect(solve_s).not_to be_nil, "no p50 solve for the shipped params in the performance table"

    # Valid-proof verify, from the verification-cost paragraph.
    verify_ms = readme[/~([\d.]+) ms for a valid proof/, 1]
    expect(verify_ms).not_to be_nil, "no valid-proof verify cost stated"

    derived = (solve_s.to_f * 1000) / verify_ms.to_f

    expect(claimed).to be_within(derived * 0.2).of(derived),
                       "the table claims a #{claimed}× lever, but this README's own numbers give " \
                       "#{derived.round}× (p50 solve #{solve_s} s ÷ valid verify #{verify_ms} ms). " \
                       "The lever is the economic argument for the toll (ADR-0007) — it is the one " \
                       "number in this file a reader will check."
  end
end
