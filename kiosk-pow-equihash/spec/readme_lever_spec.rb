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

  # The SECOND lever, and it is the one most readers of this repository are
  # actually under: `~530×` is the gem DEFAULT's, while `KIOSK_POW_DIFFICULTY=low`
  # — n=96, k=5 — is what six of the seven hosted demos and `e2e/` charge (K-1276).
  # Nothing anywhere said the deployed fleet buys an order of magnitude less
  # lever than the headline, so the README now says it; this pins it the same
  # way, by dividing this file's own two numbers, so a re-bench that moves the
  # light solve or the light verify fails here until the sentence moves with it.
  it "states a LIGHT-level lever that equals the README's own light solve ÷ light verify" do
    claimed = readme[/~([\d.]+)× at \*\*n=96, k=5\*\*/, 1]
    expect(claimed).not_to be_nil,
                          "the lever paragraph no longer states a figure for n=96 k=5. `low` is the " \
                          "level six of seven hosted origins run — if the sentence goes, the reader " \
                          "is back to reading the default's ~530× as the fleet's lever (K-1276)."
    claimed = claimed.to_f

    solve_s = readme[/n=96, k=5 \(the demos' `low`\)\s*\|\s*~?([\d.]+) s/, 1]
    expect(solve_s).not_to be_nil,
                          "no p50 solve for n=96 k=5 in the performance table — the light lever has " \
                          "no numerator to be derived from."

    verify_ms = readme[/~([\d.]+) ms for a valid proof at n=96 k=5/, 1]
    expect(verify_ms).not_to be_nil,
                            "no valid-proof verify cost stated for n=96 k=5 — the light lever has no " \
                            "denominator to be derived from."

    derived = (solve_s.to_f * 1000) / verify_ms.to_f

    expect(claimed).to be_within(derived * 0.2).of(derived),
                       "the README claims a #{claimed}× lever at n=96 k=5, but its own numbers give " \
                       "#{derived.round}× (p50 solve #{solve_s} s ÷ valid verify #{verify_ms} ms)."
  end

  # The two levers must not converge: the whole reason the second sentence
  # exists is that the deployed level buys an order of magnitude LESS.
  it "keeps the two levers an order of magnitude apart" do
    default_lever = readme[/^\| Lever \(solve\/verify\).*$/][/~?([\d,]+)×\*?\*?\s*\(/, 1].to_s.delete(",").to_i
    light_lever   = readme[/~([\d.]+)× at \*\*n=96, k=5\*\*/, 1].to_f

    expect(light_lever).to be > 0
    expect(default_lever / light_lever).to be > 5,
                                           "the default lever (#{default_lever}×) and the light one " \
                                           "(#{light_lever}×) are now within a factor of five. Either a " \
                                           "retune closed the gap — in which case say so — or one of " \
                                           "the two figures was edited without its operands."
  end
end
