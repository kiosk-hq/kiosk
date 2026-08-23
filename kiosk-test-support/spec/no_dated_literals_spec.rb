# frozen_string_literal: true

# K-972: no demo may write a CALENDAR DATE into its runtime code.
#
# WHAT WENT WRONG, and it is the reason this is a guard and not three edits.
# A verb descriptor publishes `example_params` — «copy this verbatim» — and
# three demos published a stay, a delivery and a seating on a fixed calendar
# day. Then K-969 gave those same verbs a floor («no availability in the past»),
# and the published examples turned into 400s: getgrocery's `delivery_slots`
# answered «date 2026-08-10 is in the past», atablefor's `book_table` example
# had been refused for a fortnight, and hoteling's was correct on the day it was
# measured and would have started failing on 1 September with nothing in the
# tree to notice. NOBODY EDITED ANYTHING — the tree was wrong because the clock
# moved, which is the one class of defect a review pass cannot be relied on to
# catch, because the file it has to look at has not changed.
#
# The same trap took seven driver literals in the K-969 wave and two refusal
# hints in stylish's `BookAppointmentOperation`. The shape is not «a stale
# example»; it is «assistant-facing code that names a day».
#
# THE RULE: a demo's runtime code states dates RELATIVELY, or not at all.
# `example_params` and `example_row` are RESOLVABLE SLOTS (see
# {Kiosk::Server::SchemaSlots}, K-922), so a zero-arity proc in the declaration
# is resolved when the catalog is READ and memoised for a minute — which is
# exactly the mechanism a dated example needs, and why this guard can demand a
# proc rather than merely warn:
#
#     example_params({ date: -> { DeliverySlots.example_date.iso8601 } })
#
# Prose that is not a slot — a refusal's «e.g. …» — interpolates the same helper.
#
# WHAT IT FORBIDS: a `YYYY-MM-DD` on any non-comment line of demo runtime code.
# Deliberately blunt. A narrower rule scoped to the two example macros would
# have missed stylish's refusal hints, which are the same defect one layer down,
# and every date-shaped literal that turned up in the measured scope was an
# instance of the class rather than a false positive — so the exception list is
# EMPTY, and it should stay that way.
#
# WHAT IT CANNOT CATCH, stated plainly because a regex over source is not a
# proof:
#
#   * a date assembled from parts — `"#{year}-#{month}-01"` — or read from a
#     constant in another file, from seeds, or from the environment.
#   * a fixed INSTANT written any other way: an epoch integer, a `Time.at(…)`,
#     `Date.new(2026, 9, 1)`.
#   * a date that is stale for a reason no clock fixes (a wrong copyright year).
#   * anything outside the scanned scope below.
#
# SCOPE — every DEMO's runtime code (`app/`, `config/`, `lib/` minus
# `lib/tasks/`, the same scope and reasoning as `no_interpolated_sql_spec.rb`)
# PLUS the e2e fixture host's CONTROLLERS. The second half was added by K-974,
# and the reason it is not a nicety: the fixture host publishes a real
# descriptor over a real wire, and its `book_appointment` carried
# `2026-06-15T14:00:00Z` in three declaration slots — an instant two months in
# the past — for the whole time this guard was green, because the guard only
# ever looked at `kiosk-demo-*`. A rule that holds for seven origins and not
# for the eighth is a rule with a hole in the exact shape of the thing nobody
# looks at.
#
# It is the fixture host's `*_controller.rb` and not all of `e2e/fixtures/`,
# for the same reason `script/` is excluded above: what remains dated in the
# rest of that directory is a deliberately fixed SENTINEL —
# `DemoAuditSink::EXPLODING_SLOT = "2030-01-01T00:00:00Z"`, a value the harness
# sends to prove a raising sink does not fail the booking. Nothing publishes
# it and no assistant reads it. Scoping to the descriptor-bearing files keeps
# the exception list EMPTY, which is the property this guard's header asks for.
#
# The
# `script/` drivers and demo rake tasks are excluded ON PURPOSE and the reason
# is measured, not assumed: every valid date those files use is ALREADY
# relative (`CHECK_IN = (Date.today + 30).to_s`, `DBL_IN`, `PROBE_IN`, K-969),
# and what remains hard-coded there is a deliberately HOSTILE shape — a
# `"2026-02-30"`, a `"2026-09-01'; --"`, a `"9999-12-31"` — whose whole point
# is that it is a fixed string. A guard over those would be an allowlist of
# adversarial fixtures, which is worse than the hole it closes. That hole is
# named here rather than papered over.
#
# It reads the TRACKED tree (`git ls-files`), so a vendored `.gems/` bundle is
# out of scope by construction rather than by an exclusion list, and it does
# NOT skip when the tree is not where it expects (K-502): a guard that goes
# quiet when its inputs move proves nothing after the next move.

require "open3"

DATED_REPO_ROOT = File.expand_path("../..", __dir__)

# A calendar date in ISO order. Bounded to 1000-2999 so a bare four-digit
# number followed by two hyphenated pairs — a phone number, a UUID fragment —
# is not read as a day. The trailing look-ahead is `(?![0-9])` and NOT `\b`,
# because a timestamp continues into a word character — `2026-08-10T08:00` has
# no word boundary after the day, and a `\b` there missed every `slot_at`,
# `seating_at` and `rescheduled_at` this guard was written for.
DATED_LITERAL = /\b[12][0-9]{3}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])(?![0-9])/

# Every `[lineno, source]` this file states a calendar date on.
def dated_violations(src)
  src.each_line.with_index(1).filter_map do |line, no|
    stripped = line.strip
    # Full-line comments only. A trailing `#` can live inside a string (and
    # inside a `#{…}`), and guessing which one is which is how a guard starts
    # lying — so a date in a trailing comment is FLAGGED, which is the safe
    # direction. In this tree the dated commentary is all full-line.
    next if stripped.start_with?("#")
    next unless stripped.match?(DATED_LITERAL)

    [no, stripped]
  end
end

RSpec.describe "no demo writes a calendar date into runtime code (K-972)" do
  tracked, status = Open3.capture2("git", "-C", DATED_REPO_ROOT, "ls-files", "kiosk-demo-*")
  DATED_GIT_OK = status.success?
  DATED_FILES  = tracked.lines(chomp: true).select do |f|
    f.end_with?(".rb") &&
      f.match?(%r{\Akiosk-demo-[a-z0-9_]+/(app|config|lib)/}) &&
      !f.match?(%r{\Akiosk-demo-[a-z0-9_]+/lib/tasks/})
  end.sort.freeze

  # The e2e fixture host's descriptor-bearing files (K-974). Same rule, same
  # reason, different directory — see the scope note in the header.
  e2e_tracked, e2e_status = Open3.capture2("git", "-C", DATED_REPO_ROOT, "ls-files", "e2e/fixtures")
  DATED_E2E_GIT_OK = e2e_status.success?
  DATED_E2E_FILES  = e2e_tracked.lines(chomp: true).select { |f| f.end_with?("_controller.rb") }.sort.freeze

  it "reads the tracked runtime tree (this spec never skips)" do
    expect(DATED_GIT_OK).to be(true), "git ls-files failed in #{DATED_REPO_ROOT}"
    expect(DATED_FILES.size).to be >= 150,
                                "found only #{DATED_FILES.size} tracked runtime .rb files under the demos — " \
                                "this guard has drifted, fix the scope"
    # Every demo must be represented: a rename that moved one app out of the
    # glob would otherwise shrink the scope silently.
    expect(DATED_FILES.map { |f| f[%r{\Akiosk-demo-[a-z0-9_]+}] }.uniq.size).to eq(8)
  end

  it "reads the e2e fixture host's controllers too (K-974)" do
    expect(DATED_E2E_GIT_OK).to be(true), "git ls-files failed in #{DATED_REPO_ROOT}"
    # A rename that moved the descriptor-bearing fixtures out of this glob
    # would otherwise empty the scope and stay green — the exact way this
    # guard missed `bookings_controller.rb` for as long as it did.
    expect(DATED_E2E_FILES).to include("e2e/fixtures/bookings_controller.rb")
    expect(DATED_E2E_FILES.size).to be >= 2
  end

  it "finds no calendar date in any demo's runtime code" do
    report = (DATED_FILES + DATED_E2E_FILES).flat_map do |rel|
      dated_violations(File.read(File.join(DATED_REPO_ROOT, rel)))
        .map { |no, src| "#{rel}:#{no}  #{src[0, 110]}" }
    end

    expect(report).to be_empty,
                      "a demo states a calendar date in runtime code (K-972). A written-down day " \
                      "ages into a 400 with nothing in the tree changing. In a descriptor use a " \
                      "RESOLVABLE SLOT — `example_params({ date: -> { Model.example_date.iso8601 } })`, " \
                      "see Kiosk::Server::SchemaSlots — and in prose interpolate the same helper.\n" +
                      report.join("\n")
  end

  # ── the shapes it forbids, and the ones it must not ───────────────────────
  #
  # Written against strings rather than the tree, because what has to hold is
  # the RULE, and (after K-972) the tree is clean — an example that only ever
  # sees clean sources cannot show which shape it would have caught.
  describe "the shapes it forbids, and the ones it does not" do
    it "FORBIDS a dated example_params" do
      src = %(  example_params({ date: "2026-08-10", delivery_address: "42 Camden Street" })\n)
      expect(dated_violations(src).map(&:first)).to eq([1])
    end

    it "FORBIDS a dated example_row, including a timestamp" do
      src = %(  example_row({ slot_at: "2026-08-10T08:00:00+01:00" })\n)
      expect(dated_violations(src).map(&:first)).to eq([1])
    end

    it "FORBIDS a date buried in a sentence rather than standing alone" do
      src = %(    room_types_scope: "free 2026-09-01..2026-09-04",\n)
      expect(dated_violations(src).map(&:first)).to eq([1])
    end

    it "FORBIDS a dated «e.g.» inside a refusal message" do
      src = %(      refused("missing field: slot — an ISO 8601 timestamp, e.g. \\"2026-10-01T14:00:00Z\\"")\n)
      expect(dated_violations(src).map(&:first)).to eq([1])
    end

    it "ALLOWS the resolvable-slot form the engine resolves per read" do
      src = %(  example_params({ date: -> { DeliverySlots.example_date.iso8601 } })\n)
      expect(dated_violations(src)).to be_empty
    end

    it "ALLOWS a date computed relative to now" do
      expect(dated_violations(%(  CHECK_IN = (Date.today + 30).to_s.freeze\n))).to be_empty
    end

    it "ALLOWS a full-line comment that shows the forbidden shape" do
      expect(dated_violations(%(  # it published check_in: "2026-09-01" until K-972\n))).to be_empty
    end

    it "ALLOWS a wall-clock time, which never ages" do
      expect(dated_violations(%(  example_params({ time: "20:00" })\n))).to be_empty
    end

    it "ALLOWS a version or an id that merely looks numeric" do
      src = %(  PIN = "0.4.5"\n  ID = "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e"\n)
      expect(dated_violations(src)).to be_empty
    end

    it "cannot see a date assembled from parts, or written as a Date (KNOWN blind spots)" do
      expect(dated_violations(%(  date = "\#{Date.today.year}-09-01"\n))).to be_empty
      expect(dated_violations(%(  date = Date.new(2026, 9, 1).iso8601\n))).to be_empty
    end
  end
end
