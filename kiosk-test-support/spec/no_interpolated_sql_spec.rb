# frozen_string_literal: true

# No demo may splice a VALUE into SQL statement text. The demos are the
# reference a provider copies to build an origin, and
# `"… WHERE id = #{conn.quote(id)}::uuid"` becomes an injection the first time
# somebody copies it without the `quote`. The engine writes its statements with
# `$N` binds, and the demos do the same.
#
# It forbids two shapes:
#
#   A. a `connection.quote` / `quote_string` call anywhere in demo runtime
#      code. That method only makes a Ruby value safe to paste into statement
#      text; a bind parameter needs no quoting.
#   B. `#{…}` inside SQL statement text: a SQL-tagged heredoc body, or a string
#      fragment that opens with a SQL statement or clause keyword.
#
# A regex over source is not a proof. It cannot see:
#
#   * a statement assembled from pieces (`sql = +"UPDATE t "; sql << cond`),
#     where no single fragment both opens with a keyword and interpolates;
#   * a statement built by `format`/`%`, or read from a file, a constant in
#     another file, or the environment;
#   * a splice in the middle of a string that does not open with a clause
#     keyword (`where("… = #{v}")` is flagged only because it opens with one);
#   * raw SQL without interpolated values, which is not this check's subject;
#   * anything outside the scope below.
#
# Scope: runtime code only, that is `app/`, `config/`, and `lib/` without
# `lib/tasks/`. Demo rake tasks and `script/` drivers are out of scope: they
# check database state through `psql` with ids they minted themselves, and they
# never serve a protocol request. It reads the tracked tree (`git ls-files`), and it
# never skips.

require_relative 'support/demo_runtime_files'

module InterpolatedSql
  REPO_ROOT = File.expand_path('../..', __dir__)

  # A string fragment that OPENS with a SQL statement or clause keyword. The
  # anchor keeps English prose out ("… the YYYY-MM-DD from an availability row").
  CLAUSE = /\A\s*(SELECT|INSERT\s+INTO|UPDATE\s|DELETE\s+FROM|CREATE\s+(TABLE|INDEX|SCHEMA)|
                ALTER\s+TABLE|DROP\s+TABLE|TRUNCATE|WITH\s|WHERE\s|AND\s|SET\s|FROM\s|
                JOIN\s|LEFT\s+JOIN|INNER\s+JOIN|RETURNING\s|VALUES\s|VALUES\(|ORDER\s+BY|
                GROUP\s+BY|LIMIT\s|ON\s+CONFLICT|HAVING\s|FOR\s+UPDATE)/xi

  QUOTE_CALL = /\.quote(?:_string)?\s*\(/
  SQL_HEREDOC = /<<[-~]?['"]?(SQL[A-Z0-9_]*)['"]?/
  STRING_FRAGMENT = /"((?:[^"\\]|\\.)*)"/

  # Known sites with an exact count each. A new splice in a listed file fails,
  # and so does a listed file that has become clean: delete its entry then.
  KNOWN = {}.freeze

  module_function

  # Every `[lineno, why, source]` this source splices, in file order.
  def violations(src)
    out     = []
    heredoc = nil
    src.each_line.with_index(1) { |line, lineno| heredoc = scan_line(line, lineno, heredoc, out) }
    out
  end

  # Records the violations of one line and returns the SQL heredoc tag that is
  # open after it, or nil.
  def scan_line(line, lineno, heredoc, out)
    stripped = line.strip
    return heredoc_line(stripped, lineno, heredoc, out) if heredoc
    # Full-line comments only: a `#` can also sit inside a string.
    return nil if stripped.start_with?('#')

    out << [lineno, 'hand-quoted value (`.quote(`)', stripped] if line.match?(QUOTE_CALL)
    out << [lineno, 'interpolation inside SQL statement text', stripped] if spliced_fragment?(line)
    line[SQL_HEREDOC, 1]
  end

  def heredoc_line(stripped, lineno, heredoc, out)
    out << [lineno, 'interpolation inside a SQL heredoc', stripped] if stripped.include?('#{')
    stripped == heredoc ? nil : heredoc
  end

  def spliced_fragment?(line)
    line.scan(STRING_FRAGMENT).any? { |(fragment)| fragment.match?(CLAUSE) && fragment.include?('#{') }
  end

  # Report lines for the files with violations that KNOWN does not account for,
  # and for KNOWN entries whose file is clean now.
  def report(found)
    grown = found.reject { |rel, sites| KNOWN[rel] == sites.size }
    grown.flat_map { |rel, sites| site_lines(rel, sites) } +
      KNOWN.keys.reject { |rel| found.key?(rel) }.map { |rel| "#{rel}: clean now — delete its SQLI_KNOWN entry" }
  end

  def site_lines(rel, sites)
    [head(rel, sites.size)] + sites.map { |lineno, why, src| "    :#{lineno} #{why} — #{src[0, 100]}" }
  end

  def head(rel, count)
    known = KNOWN[rel]
    known.nil? ? "#{rel}: #{count} interpolated-SQL site(s), none expected" : "#{rel}: #{count} site(s), SQLI_KNOWN says #{known}"
  end
end

RSpec.describe 'no demo splices a value into SQL statement text (K-654)' do
  let(:git_ok) { DemoRuntimeFiles.list.first }
  let(:files)  { DemoRuntimeFiles.list.last }

  it 'reads the tracked runtime tree (this spec never skips)' do
    expect(git_ok).to be(true), "git ls-files failed in #{InterpolatedSql::REPO_ROOT}"
    expect(files.size).to be >= 150,
                          "found only #{files.size} tracked runtime .rb files under the demos — " \
                          'this guard has drifted, fix the scope'
    # A rename that moved one app out of the glob would shrink the scope silently.
    expect(DemoRuntimeFiles.demos(files).size).to eq(8)
  end

  it 'lists no site that has since been deleted' do
    missing = InterpolatedSql::KNOWN.keys.reject { |f| File.exist?(File.join(InterpolatedSql::REPO_ROOT, f)) }
    expect(missing).to be_empty, "SQLI_KNOWN names files that no longer exist: #{missing.inspect}"
  end

  it 'finds no interpolated SQL outside the listed sites, and none of those has grown' do
    found = files.to_h { |rel| [rel, InterpolatedSql.violations(File.read(File.join(InterpolatedSql::REPO_ROOT, rel)))] }
                 .reject { |_, sites| sites.empty? }
    report = InterpolatedSql.report(found)

    expect(report).to be_empty,
                      'a demo splices a value into SQL statement text (K-654). Pass it as a bind ' \
                      'parameter instead — `conn.exec_update("UPDATE t SET s = $1 WHERE id = $2::uuid", ' \
                      "\"label\", [s, id])` — the way kiosk-server's executor.rb does.\n#{report.join("\n")}"
  end

  # Written against strings rather than the tree: on a clean tree only examples
  # like these show which shapes the rule catches.
  describe 'the interpolated-SQL shapes it forbids' do
    it 'FORBIDS a quoted value spliced into an UPDATE' do
      v = InterpolatedSql.violations(%(conn.execute("UPDATE orders SET status = \#{conn.quote(to)} WHERE id = 1")\n))
      expect(v.map { |x| x[1] }).to include('hand-quoted value (`.quote(`)', 'interpolation inside SQL statement text')
    end

    it 'FORBIDS a bare splice into a WHERE continuation fragment' do
      v = InterpolatedSql.violations(%(  "WHERE id = '\#{order_id}'::uuid " \\\n))
      expect(v.first[1]).to eq('interpolation inside SQL statement text')
    end

    it 'FORBIDS a splice inside a SQL-tagged heredoc body' do
      src = "sql = <<~SQL\n  UPDATE t SET s = '\#{value}'\nSQL\n"
      expect(InterpolatedSql.violations(src).first[1]).to eq('interpolation inside a SQL heredoc')
    end

    # The `quote` call is caught by rule A; the splice itself is invisible to
    # rule B, which is why rule A exists.
    it 'cannot see a statement assembled from pieces (a KNOWN blind spot)' do
      src = %(sql = +"UPDATE orders SET status = "\nsql << conn.quote(to)\n)
      expect(InterpolatedSql.violations(src).map { |x| x[1] }).to eq(['hand-quoted value (`.quote(`)'])
    end
  end

  describe 'the interpolated-SQL shapes it allows' do
    it 'ALLOWS the bind-parameter form the engine uses' do
      src = %(conn.exec_update("UPDATE orders SET status = $1 WHERE id = $2::uuid", "flip", [to, id])\n)
      expect(InterpolatedSql.violations(src)).to be_empty
    end

    it 'ALLOWS an ActiveRecord relation carrying the value out of the string' do
      expect(InterpolatedSql.violations(%(Order.where(id: order_id, status: "created").pick(:total_cents)\n))).to be_empty
    end

    it 'ALLOWS English prose that happens to contain a SQL word' do
      src = %(bad_request("invalid date: \#{date} — use the YYYY-MM-DD from an availability row")\n)
      expect(InterpolatedSql.violations(src)).to be_empty
    end

    it 'ALLOWS a full-line comment that shows the forbidden shape' do
      expect(InterpolatedSql.violations(%(  # was: "WHERE id = \#{conn.quote(id)}::uuid"\n))).to be_empty
    end
  end
end
