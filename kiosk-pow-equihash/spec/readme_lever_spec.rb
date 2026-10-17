# frozen_string_literal: true

# The README's solve/verify LEVER is the price that a metered toll puts on
# abuse. Each lever the README states must equal the README's own solve time
# divided by its own verify time, so a re-bench or a retune fails here until the
# stated lever moves with it. The check is an order of magnitude (within 20%),
# because the operands are a p50 and a median measured on one laptop.
module ReadmeLever
  README = File.read(File.expand_path('../README.md', __dir__))
  GEMSPEC = File.read(File.expand_path('../kiosk-pow-equihash.gemspec', __dir__))
  LEVER_ROW = %r{^\| Lever \(solve/verify\).*$}

  module_function

  def default_lever_row = README[LEVER_ROW]

  # The numeric ratio in the comparison table's lever row, or nil.
  def default_lever(row = default_lever_row)
    row[/~?([\d,]+)×\*?\*?\s*\(/, 1] || row[/\*\*~?([\d,]+)×\*\*/, 1]
  end

  # The valid-proof verify cost at the shipped default, in ms.
  def verify_ms = README[/~([\d.]+) ms for a valid proof/, 1]

  def derived(solve_s, verify_ms) = (solve_s.to_f * 1000) / verify_ms.to_f
end

RSpec.describe "the README's default solve/verify lever" do
  it "states a lever that equals the README's own solve ÷ verify" do
    row = ReadmeLever.default_lever_row
    expect(row).not_to be_nil, 'the comparison table has no `Lever (solve/verify)` row'
    claimed = ReadmeLever.default_lever(row)
    expect(claimed).not_to be_nil,
                           "the lever row states no numeric ratio: #{row.strip.inspect}. " \
                           'A word ("millions×") is not a measurement — state the number this ' \
                           "README's own benchmarks give, or state that it is unbenched."
    # p50 solve at the shipped default, from the performance table.
    solve_s = ReadmeLever::README[/\*\*n=168, k=7 \(default\)\*\*\s*\|\s*~?([\d.]+) s/, 1]
    expect(solve_s).not_to be_nil, 'no p50 solve for the shipped params in the performance table'
    expect(ReadmeLever.verify_ms).not_to be_nil, 'no valid-proof verify cost stated'

    derived = ReadmeLever.derived(solve_s, ReadmeLever.verify_ms)
    expect(claimed.delete(',').to_i).to be_within(derived * 0.2).of(derived),
                                        "the table claims a #{claimed}× lever, but this README's own numbers give " \
                                        "#{derived.round}× (p50 solve #{solve_s} s ÷ valid verify #{ReadmeLever.verify_ms} ms). " \
                                        'The lever is the economic argument for the toll — it is the one ' \
                                        'number in this file a reader will check.'
  end
end

# The gemspec `summary` and `description` are what rubygems.org prints. Every
# millisecond figure in them must be the README's valid-proof verify cost: it is
# the only millisecond quantity this gem has.
RSpec.describe "the gemspec's verify cost" do
  it 'states the same verify cost in the gemspec as in the README' do
    verify_ms = ReadmeLever.verify_ms
    expect(verify_ms).not_to be_nil, 'no valid-proof verify cost stated in the README'
    stated = ReadmeLever::GEMSPEC.scan(/~([\d.]+) ms/).flatten
    expect(stated).not_to be_empty,
                          'the gemspec states no millisecond figure at all. If the verify cost was ' \
                          'deliberately dropped from the blurb, drop this example with it — do not ' \
                          'leave an example that passes by matching nothing.'

    disagreeing = stated.reject { |ms| ms == verify_ms }
    expect(disagreeing).to be_empty,
                           "the gemspec says ~#{disagreeing.uniq.join('/')} ms where the README says " \
                           "~#{verify_ms} ms for a valid proof. The README figure is the one the " \
                           'lever derivation above is computed from; the gemspec is the copy ' \
                           'rubygems.org prints. Move them together or state why they differ.'
  end
end
