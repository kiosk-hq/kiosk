# frozen_string_literal: true

# K-654: no demo may splice a VALUE into SQL statement text.
#
# WHY THIS GUARD EXISTS AT ALL, given that nothing it catches is exploitable
# today. Every site it was written against passed its values through
# `connection.quote` first, so none of them was injectable — Phil's brakeman
# run over all eight apps says so, and the ledger records it. The charge is not
# safety, it is EXEMPLARITY: the demos are the reference a provider copies to
# build their own origin, and `"… WHERE id = #{conn.quote(id)}::uuid"` is the
# shape that becomes an injection the first time somebody copies it and forgets
# the `quote`. The engine gave the idiom up first (`executor.rb` writes every
# pay-path statement through `$N` binds), and the demos may not keep teaching
# what the engine stopped doing.
#
# WHAT IT FORBIDS — two shapes, both mechanical:
#
#   A. a `connection.quote` / `quote_string` call anywhere in demo runtime
#      code. That method exists for exactly one purpose: to make a Ruby value
#      safe to paste into statement text. A bind parameter needs no quoting, so
#      a `quote` call IS the confession.
#   B. `#{…}` inside SQL statement text — a SQL-tagged heredoc body, or a
#      string fragment that opens with a SQL statement or clause keyword.
#
# WHAT IT CANNOT CATCH, stated plainly because a regex over source is not a
# proof and should not be sold as one:
#
#   * a statement ASSEMBLED from pieces — `sql = +"UPDATE t "; sql << cond` —
#     where no single fragment both opens with a keyword and interpolates.
#   * a statement built by `format`/`%`, or read from a file, a constant in
#     another file, or the environment.
#   * `sanitize_sql_array`, `where("… = ?", v)` and friends: those are
#     parameterised and correctly not flagged, but a `where("… = #{v}")` IS
#     flagged only because the fragment opens with a clause keyword — a
#     mid-string splice into an already-open statement is invisible.
#   * NON-interpolated raw SQL. `atablefor`'s dashboard SELECT hand-pulls the
#     connection and writes bare SQL with no values at all; that is K-781's
#     subject, not this one, and this guard is silent on it BY DESIGN — the
#     defect here is the value splice.
#   * anything outside the scanned scope below.
#
# SCOPE — RUNTIME code only: `app/`, `config/`, and `lib/` minus `lib/tasks/`.
# Demo rake tasks and `script/` drivers are excluded on purpose: they assert DB
# ground truth by shelling out to `psql -tAc "SELECT … WHERE id = '#{id}'"`
# with an id the task itself just minted, they never serve a wire request, and
# nobody copies a demo's test harness to build a provider origin. That is a
# real hole and it is named here rather than papered over.
#
# It reads the TRACKED tree (`git ls-files`), so a vendored `.gems/` bundle is
# out of scope by construction rather than by an exclusion list, and it does
# NOT skip when the tree is not where it expects (K-502): a guard that goes
# quiet when its inputs move proves nothing after the next move.

require "open3"

SQLI_REPO_ROOT = File.expand_path("../..", __dir__)

# A string fragment that OPENS with a SQL statement or clause keyword. Anchoring
# at the start is what keeps English prose out: "… use the YYYY-MM-DD from an
# availability row" contains `FROM`, and an unanchored keyword search flagged
# fourteen such sentences when this guard was first prototyped.
SQLI_CLAUSE = /\A\s*(SELECT|INSERT\s+INTO|UPDATE\s|DELETE\s+FROM|CREATE\s+(TABLE|INDEX|SCHEMA)|
                     ALTER\s+TABLE|DROP\s+TABLE|TRUNCATE|WITH\s|WHERE\s|AND\s|SET\s|FROM\s|
                     JOIN\s|LEFT\s+JOIN|INNER\s+JOIN|RETURNING\s|VALUES\s|VALUES\(|ORDER\s+BY|
                     GROUP\s+BY|LIMIT\s|ON\s+CONFLICT|HAVING\s|FOR\s+UPDATE)/xi

SQLI_QUOTE_CALL = /\.quote(?:_string)?\s*\(/

# Known sites, each with the row that owns it and an exact count. The count is
# the ratchet: a NEW splice in an already-listed file fails just as loudly as
# one in a clean file, and REMOVING the debt fails too — which is the reminder
# to delete the entry rather than let it rot into a permanent licence.
#
# Two kinds of entry, and they are not the same thing:
#   DEBT     — really is the K-654 shape, owned by another row.
#   ACCEPTED — correct code this regex cannot tell apart from the bad shape.
SQLI_KNOWN = {
  # ACCEPTED — the bind-PLACEHOLDER idiom, which is the opposite of a splice:
  # `$1::uuid, $2::uuid, …` is generated from the ARITY of the id list and the
  # ids themselves travel as binds. A worked example of what this guard wants.
  "kiosk-demo-tudu/app/controllers/lists_controller.rb" => 1,
}.merge(
  # DEBT — K-714 owns `demo_telemetry.rb`: it builds its INSERT as a heredoc
  # with four `conn.quote` splices and interpolates its table-name constant.
  # Byte-identical in seven demos (bin/check-demo-copies pins that), so the
  # count is stated once and applied to each copy.
  %w[atablefor getgrocery hoteling philslist skooti stylish tudu].to_h do |demo|
    ["kiosk-demo-#{demo}/app/services/demo_telemetry.rb", 18]
  end,
).freeze

# Every `[lineno, why, source]` this file splices, in file order.
def sqli_violations(src)
  out     = []
  heredoc = nil

  src.each_line.with_index(1) do |line, no|
    stripped = line.strip

    if heredoc
      out << [no, "interpolation inside a SQL heredoc", stripped] if stripped.include?('#{')
      heredoc = nil if stripped == heredoc
      next
    end

    # Full-line comments only. Trailing comments are not stripped: a `#` can
    # live inside a string, and guessing which one is which is how a guard
    # starts lying. In this tree the SQL commentary is all full-line.
    next if stripped.start_with?("#")

    heredoc = Regexp.last_match(1) if line =~ /<<[-~]?['"]?(SQL[A-Z0-9_]*)['"]?/

    out << [no, "hand-quoted value (`.quote(`)", stripped] if line =~ SQLI_QUOTE_CALL

    next unless stripped.include?('#{')

    line.scan(/"((?:[^"\\]|\\.)*)"/) do |(fragment)|
      next unless fragment =~ SQLI_CLAUSE && fragment.include?('#{')

      out << [no, "interpolation inside SQL statement text", stripped]
      break
    end
  end

  out
end

RSpec.describe "no demo splices a value into SQL statement text (K-654)" do
  tracked, status = Open3.capture2("git", "-C", SQLI_REPO_ROOT, "ls-files", "kiosk-demo-*")
  SQLI_GIT_OK = status.success?
  SQLI_FILES  = tracked.lines(chomp: true).select do |f|
    f.end_with?(".rb") &&
      f.match?(%r{\Akiosk-demo-[a-z0-9_]+/(app|config|lib)/}) &&
      !f.match?(%r{\Akiosk-demo-[a-z0-9_]+/lib/tasks/})
  end.sort.freeze

  it "reads the tracked runtime tree (this spec never skips)" do
    expect(SQLI_GIT_OK).to be(true), "git ls-files failed in #{SQLI_REPO_ROOT}"
    expect(SQLI_FILES.size).to be >= 150,
                               "found only #{SQLI_FILES.size} tracked runtime .rb files under the demos — " \
                               "this guard has drifted, fix the scope"
    # Every demo must be represented: a rename that moved one app out of the
    # glob would otherwise shrink the scope silently.
    expect(SQLI_FILES.map { |f| f[%r{\Akiosk-demo-[a-z0-9_]+}] }.uniq.size).to eq(8)
  end

  it "lists no site that has since been deleted" do
    missing = SQLI_KNOWN.keys.reject { |f| File.exist?(File.join(SQLI_REPO_ROOT, f)) }
    expect(missing).to be_empty, "SQLI_KNOWN names files that no longer exist: #{missing.inspect}"
  end

  it "finds no interpolated SQL outside the listed sites, and none of those has grown" do
    found = SQLI_FILES.to_h { |rel| [rel, sqli_violations(File.read(File.join(SQLI_REPO_ROOT, rel)))] }
                      .reject { |_, v| v.empty? }

    report = found.reject { |rel, v| SQLI_KNOWN[rel] == v.size }.flat_map do |rel, v|
      known = SQLI_KNOWN[rel]
      head  = known.nil? ? "#{rel}: #{v.size} interpolated-SQL site(s), none expected" : "#{rel}: #{v.size} site(s), SQLI_KNOWN says #{known}"
      [head] + v.map { |no, why, src| "    :#{no} #{why} — #{src[0, 100]}" }
    end

    # A listed file that has gone CLEAN is also a failure: delete its entry.
    drained = SQLI_KNOWN.keys.reject { |rel| found.key?(rel) }

    expect(report + drained.map { |rel| "#{rel}: clean now — delete its SQLI_KNOWN entry" }).to be_empty,
      "a demo splices a value into SQL statement text (K-654). Pass it as a bind " \
      "parameter instead — `conn.exec_update(\"UPDATE t SET s = $1 WHERE id = $2::uuid\", " \
      "\"label\", [s, id])` — the way kiosk-server's executor.rb does.\n" +
      (report + drained.map { |rel| "#{rel}: clean now — delete its SQLI_KNOWN entry" }).join("\n")
  end

  # ── the shapes it forbids, and the ones it must not ───────────────────────
  #
  # Written against strings rather than the tree, because what has to hold is
  # the RULE, and (after this row) the tree is clean — an example that only
  # ever sees clean sources cannot show which shape it would have caught.
  describe "the shapes it forbids, and the ones it does not" do
    it "FORBIDS a quoted value spliced into an UPDATE" do
      v = sqli_violations(%(conn.execute("UPDATE orders SET status = \#{conn.quote(to)} WHERE id = 1")\n))
      expect(v.map { |x| x[1] }).to include("hand-quoted value (`.quote(`)",
                                            "interpolation inside SQL statement text")
    end

    it "FORBIDS a bare splice into a WHERE continuation fragment" do
      v = sqli_violations(%(  "WHERE id = '\#{order_id}'::uuid " \\\n))
      expect(v.first[1]).to eq("interpolation inside SQL statement text")
    end

    it "FORBIDS a splice inside a SQL-tagged heredoc body" do
      src = "sql = <<~SQL\n  UPDATE t SET s = '\#{value}'\nSQL\n"
      expect(sqli_violations(src).first[1]).to eq("interpolation inside a SQL heredoc")
    end

    it "ALLOWS the bind-parameter form the engine uses" do
      src = %(conn.exec_update("UPDATE orders SET status = $1 WHERE id = $2::uuid", "flip", [to, id])\n)
      expect(sqli_violations(src)).to be_empty
    end

    it "ALLOWS an ActiveRecord relation carrying the value out of the string" do
      expect(sqli_violations(%(Order.where(id: order_id, status: "created").pick(:total_cents)\n))).to be_empty
    end

    it "ALLOWS English prose that happens to contain a SQL word" do
      src = %(bad_request("invalid date: \#{date} — use the YYYY-MM-DD from an availability row")\n)
      expect(sqli_violations(src)).to be_empty
    end

    it "ALLOWS a full-line comment that shows the forbidden shape" do
      expect(sqli_violations(%(  # was: "WHERE id = \#{conn.quote(id)}::uuid"\n))).to be_empty
    end

    it "cannot see a statement assembled from pieces (a KNOWN blind spot)" do
      src = %(sql = +"UPDATE orders SET status = "\nsql << conn.quote(to)\n)
      # The `quote` call is still caught — that is rule A doing the work — but
      # the splice itself is invisible to rule B, which is why rule A exists.
      expect(sqli_violations(src).map { |x| x[1] }).to eq(["hand-quoted value (`.quote(`)"])
    end
  end
end
