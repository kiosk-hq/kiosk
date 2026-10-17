# frozen_string_literal: true

# No demo may write a CALENDAR DATE into its runtime code. A verb descriptor
# publishes `example_params` for an assistant to copy, and a verb may refuse a
# date in the past. A written-down day therefore turns into a 400 when the
# clock moves, with no change in the tree for a review to see.
#
# The rule: a demo's runtime code states dates relative to now, or not at all.
# `example_params` and `example_row` are resolvable slots
# ({Kiosk::Server::SchemaSlots}): a zero-arity proc in the declaration is
# resolved when the catalog is read, so a dated example is a proc:
#
#     example_params({ date: -> { DeliverySlots.default_zone.tomorrow.iso8601 } })
#
# Prose that is not a slot, such as a refusal's «e.g. …», interpolates the same
# helper.
#
# It forbids a `YYYY-MM-DD` on any non-comment line of the scope. The rule is
# blunt on purpose: a rule scoped to the example macros would miss a refusal
# hint, which is the same defect. The exception list is empty.
#
# A regex over source is not a proof. It cannot see:
#
#   * a date assembled from parts (`"#{year}-#{month}-01"`), or read from a
#     constant in another file, from seeds, or from the environment;
#   * a fixed instant written another way: an epoch integer, `Time.at(…)`,
#     `Date.new(2026, 9, 1)`;
#   * a date that is stale for a reason no clock fixes (a wrong copyright year);
#   * anything outside the scope below.
#
# Scope: every demo's runtime code (as in `no_interpolated_sql_spec.rb`) and
# the e2e fixture host's `*_controller.rb` files, which publish a real
# descriptor over a real wire. The rest of `e2e/fixtures/` holds a fixed
# sentinel that nothing publishes. The `script/` drivers and demo rake tasks
# are out of scope: their valid dates are already relative, and their fixed
# dates are hostile inputs (`"2026-02-30"`, `"9999-12-31"`) that must stay
# fixed. It reads the tracked tree and never skips.

require 'open3'
require_relative 'support/demo_runtime_files'

module DatedLiterals
  REPO_ROOT = DemoRuntimeFiles::REPO_ROOT

  # A calendar date in ISO order, years 1000-2999, so a phone number or a UUID
  # fragment is not read as a day. The end is `(?![0-9])`, not `\b`: a
  # timestamp continues into a word character (`2026-08-10T08:00`).
  LITERAL = /\b[12][0-9]{3}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])(?![0-9])/

  module_function

  # [git succeeded?, the e2e fixture host's controller files]
  def e2e_files
    tracked, status = Open3.capture2('git', '-C', REPO_ROOT, 'ls-files', 'e2e/fixtures')
    [status.success?, tracked.lines(chomp: true).select { |f| f.end_with?('_controller.rb') }.sort.freeze]
  end

  # Every `[lineno, source]` this source states a calendar date on. Only
  # full-line comments are skipped: a `#` can also sit inside a string, so a
  # date in a trailing comment is flagged, which is the safe direction.
  def violations(src)
    src.each_line.with_index(1).filter_map do |line, lineno|
      stripped = line.strip
      [lineno, stripped] if !stripped.start_with?('#') && stripped.match?(LITERAL)
    end
  end

  def report(files)
    files.flat_map do |rel|
      violations(File.read(File.join(REPO_ROOT, rel))).map { |lineno, src| "#{rel}:#{lineno}  #{src[0, 110]}" }
    end
  end
end

RSpec.describe 'no demo writes a calendar date into runtime code (K-972)' do
  let(:demo_files) { DemoRuntimeFiles.list }
  let(:e2e_files)  { DatedLiterals.e2e_files }

  it 'reads the tracked runtime tree (this spec never skips)' do
    git_ok, files = demo_files
    expect(git_ok).to be(true), "git ls-files failed in #{DatedLiterals::REPO_ROOT}"
    expect(files.size).to be >= 150,
                          "found only #{files.size} tracked runtime .rb files under the demos — " \
                          'this guard has drifted, fix the scope'
    # A rename that moved one app out of the glob would shrink the scope silently.
    expect(DemoRuntimeFiles.demos(files).size).to eq(8)
  end

  # A rename that moved the descriptor-bearing fixtures out of the glob would
  # empty the scope and stay green.
  it "reads the e2e fixture host's controllers too (K-974)" do
    git_ok, files = e2e_files
    expect(git_ok).to be(true), "git ls-files failed in #{DatedLiterals::REPO_ROOT}"
    expect(files).to include('e2e/fixtures/bookings_controller.rb')
    expect(files.size).to be >= 2
  end

  it "finds no calendar date in any demo's runtime code" do
    report = DatedLiterals.report(demo_files.last + e2e_files.last)

    expect(report).to be_empty,
                      'a demo states a calendar date in runtime code (K-972). A written-down day ' \
                      'ages into a 400 with nothing in the tree changing. In a descriptor use a ' \
                      'RESOLVABLE SLOT — `example_params({ date: -> { Time.find_zone!("Europe/Dublin").tomorrow.iso8601 } })`, ' \
                      "see Kiosk::Server::SchemaSlots — and in prose interpolate the same helper.\n#{report.join("\n")}"
  end
end

# Written against strings rather than the tree: on a clean tree only examples
# like these show which shapes the rule catches.
RSpec.describe 'the dated-literal shapes it forbids' do
  {
    'FORBIDS a dated example_params' => %(  example_params({ date: "2026-08-10", delivery_address: "42 Camden Street" })\n),
    'FORBIDS a dated example_row, including a timestamp' => %(  example_row({ slot_at: "2026-08-10T08:00:00+01:00" })\n),
    'FORBIDS a date buried in a sentence rather than standing alone' => %(    room_types_scope: "free 2026-09-01..2026-09-04",\n),
    'FORBIDS a dated «e.g.» inside a refusal message' =>
      %(      refused("missing field: slot — an ISO 8601 timestamp, e.g. \\"2026-10-01T14:00:00Z\\"")\n)
  }.each do |label, src|
    it label do
      expect(DatedLiterals.violations(src).map(&:first)).to eq([1])
    end
  end
end

RSpec.describe 'the dated-literal shapes it allows' do
  {
    'ALLOWS the resolvable-slot form the engine resolves per read' =>
      %(  example_params({ date: -> { DeliverySlots.default_zone.tomorrow.iso8601 } })\n),
    'ALLOWS a date computed relative to now' => %(  CHECK_IN = (Date.today + 30).to_s.freeze\n),
    'ALLOWS a full-line comment that shows the forbidden shape' => %(  # it published check_in: "2026-09-01" until K-972\n),
    'ALLOWS a wall-clock time, which never ages' => %(  example_params({ time: "20:00" })\n),
    'ALLOWS a version or an id that merely looks numeric' =>
      %(  PIN = "0.4.5"\n  ID = "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e"\n)
  }.each do |label, src|
    it label do
      expect(DatedLiterals.violations(src)).to be_empty
    end
  end

  it 'cannot see a date assembled from parts, or written as a Date (KNOWN blind spots)' do
    expect(DatedLiterals.violations(%(  date = "\#{Date.today.year}-09-01"\n))).to be_empty
    expect(DatedLiterals.violations(%(  date = Date.new(2026, 9, 1).iso8601\n))).to be_empty
  end
end
