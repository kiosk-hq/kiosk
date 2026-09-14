#!/usr/bin/env ruby
# frozen_string_literal: true

# check_grammar_coverage.rb — the canonical grammar page and the shared vector
# set answer to each other.
#
# Run by `make crosscheck` (and therefore by `make test`) as:
#   ruby check_grammar_coverage.rb
#   ruby check_grammar_coverage.rb --self-test
#
# WHY THIS EXISTS, from what happened rather than from principle. The rental
# token has three readers and two things that are supposed to keep them in
# step: ../RENTAL_TOKEN.md, which STATES the grammar in prose, and
# token_vectors.rb, which PINS it in vectors `make crosscheck` runs through all
# three. Those two were written by hand, separately, and nothing compared them.
# So the page could state a rule — the signature is unpadded base64url over
# `A-Za-z0-9-_` — that no vector exercised, and it did: the two Ruby readers
# accepted a padded signature and a standard-alphabet one where the lock
# refused both, on an axis the page declared and the vector set could not
# reach. A rule nobody wrote a vector for reads exactly like a rule everybody
# implements.
#
# WHAT THIS GATE CHECKS, in both directions:
#
#   R1  Every RULE in the grammar section carries exactly one
#       `<!-- vectors: axis[, axis] -->` marker. A rule is a bullet in that
#       section or a data row of its field table.
#   R2  Every axis a marker names exists in SkootiTokenVectors.axes.
#   R3  Every axis in SkootiTokenVectors.axes is named by at least one rule.
#       This is the direction that catches a vector set drifting away from the
#       page as much as the page drifting away from the set.
#   R4  PROSE in that section — anything that is not a rule — carries no
#       normative vocabulary. A rule smuggled into a paragraph would be a rule
#       R1 never looks at, so the paragraph has to be reworded or the rule has
#       to become a bullet. A paragraph that genuinely needs the word carries a
#       marker of its own and is then read as a rule.
#   R5  Vacuity. The section exists, each of its three rule subsections yields
#       at least one rule, and the normative vocabulary R4 scans for still
#       occurs in the rules — a word list that has stopped matching anything is
#       a scan that cannot fail.
#   R6  A rule that quantifies over the BYTE DOMAIN — "any byte", "every
#       byte", "byte value", or a claim that no reader constrains a field
#       further — names an axis the vector set covers EXHAUSTIVELY, meaning
#       one vector for every one of the 256 byte values. This is the arm the
#       grammar was missing, and it is the one this gate exists for now: the
#       `reservation_id` cell read "any bytes but the delimiter and NUL… No
#       reader constrains it further", named the `bytes` axis, and PASSED R1-R5
#       while the three readers disagreed on 128 of the 256 single-byte cases.
#       An axis of five sampled bytes and an axis of all 256 are the same
#       string on the page; only the vector set can tell them apart, so it is
#       asked. The remedy on the artefact side was to NARROW the two opaque
#       fields to a set of 66 characters, because a domain that can be
#       enumerated is one a rule can honestly quantify over.
#   R7  The section carries a LIMITS subsection, and it is not empty. A page
#       that only ever states what IS true reads as complete whether it is or
#       not; the limits are where it says what it does not claim, and they are
#       structurally exempt from R1 — a limit is not a rule and naming an axis
#       for one would be a category error, so a marker there FAILS.
#
# WHAT IT DOES NOT CHECK, and both limits are the point of saying so:
#
#   * THAT A VECTOR ACTUALLY EXERCISES THE RULE IT IS NAMED BY, except on the
#     byte domain, where R6 now asks for exhaustiveness. Everywhere else R1-R3
#     bind a rule to an AXIS and an axis to at least one vector, and whether
#     those vectors reach the property the rule states is a judgement no string
#     comparison makes. `make crosscheck` answers the neighbouring question —
#     whether the three readers agree about the vectors that DO exist.
#   * A PROPERTY OF THE TOKEN NOBODY HAS WRITTEN DOWN. This gate compares two
#     artefacts with each other. An axis absent from BOTH is invisible to it,
#     and that is how the signature-encoding hole was opened in the first
#     place: the page had the rule, so the page was not the half that was
#     missing. Attacking the parse is still the only thing that finds those.

require_relative "token_vectors"

PAGE = File.expand_path("../RENTAL_TOKEN.md", __dir__)

# The section this gate reads. Named by its heading so a renamed heading is a
# loud failure rather than a silent empty scan.
SECTION_HEADING = "## Rental token: the exact grammar"

# The bold lines that open a RULE subsection inside it. Each has to yield a rule.
SUBSECTIONS = ["**Wire token**", "**Message**", "**Fields**"].freeze

# The bold line that opens the LIMITS subsection. Its bullets are limits, not
# rules: R1 does not ask them for an axis and R6 does not read them, because a
# limit's whole job is to say what the set does NOT reach. A marker inside one
# is a category error and fails.
LIMITS_SUBSECTION = "**What this section does not claim**"

# Normative vocabulary. A paragraph using any of these is stating a rule, and a
# rule belongs in a bullet or a table row where R1 can see it. Matched
# case-insensitively.
NORMATIVE = [
  "must", "may not", "at most", "at least", "exactly",
  "and nothing else", "is refused", "are refused",
  "is rejected", "are rejected", "is a refusal"
].freeze

# Vocabulary that quantifies over the BYTE DOMAIN, or denies that anything
# further constrains a field. A rule using any of these is making a claim about
# all 256 byte values whether it says the number or not, so R6 asks it to name
# an axis that has been run over all 256. Matched case-insensitively, after
# code spans are dropped — the original defect spelled its delimiter in
# backticks and would otherwise have read as "any bytes but \| and NUL".
BYTE_UNIVERSAL = [
  "any byte", "any bytes", "every byte", "all bytes", "byte value",
  "no reader constrains", "none gates on it", "nothing further"
].freeze

MARKER = /<!--\s*vectors:\s*([^>]*?)\s*-->/.freeze

# An inline code span. A marker written INSIDE one is the page quoting the
# syntax to a reader, not applying it — the paragraph that explains this gate
# spells a marker out, and without this it would read as claiming an axis. Code
# spans are dropped before both the marker scan and the vocabulary scan.
CODE_SPAN = /`[^`]*`/.freeze

Rule = Struct.new(:kind, :subsection, :line_no, :text, :axes)

def uncoded(text)
  text.gsub(CODE_SPAN, " ")
end

# Pull the grammar section out of a page. Returns its lines, or nil when the
# heading is not there.
def grammar_section(markdown)
  lines = markdown.lines.map(&:chomp)
  start = lines.index { |line| line.strip == SECTION_HEADING }
  return nil if start.nil?

  rest = lines[(start + 1)..] || []
  stop = rest.index { |line| line.start_with?("## ") }
  body = stop.nil? ? rest : rest[0...stop]
  [body, start + 2] # 1-based line number of the first body line
end

# Split the section into blocks. A bullet block is its "- " line plus every
# indented continuation line; a table data row is one line; everything else
# accumulates into prose blocks. Returns [kind, subsection, line_no, text].
def blocks(body, first_line_no)
  out     = []
  section = "(before any subsection)"
  prose   = nil
  bullet  = nil

  flush = lambda do
    out << bullet if bullet
    out << prose  if prose
    bullet = nil
    prose  = nil
  end

  body.each_with_index do |line, index|
    line_no = first_line_no + index

    if line.strip.empty?
      flush.call
      next
    end

    if SUBSECTIONS.include?(line.strip) || line.strip == LIMITS_SUBSECTION
      flush.call
      section = line.strip
      next
    end

    if line.start_with?("- ")
      flush.call
      bullet = [:bullet, section, line_no, line]
      next
    end

    if bullet && line.start_with?("  ")
      bullet[3] = "#{bullet[3]}\n#{line}"
      next
    end

    if line.start_with?("|")
      flush.call
      # Skip the header row and the --- separator row of a table.
      next if line.match?(/\A\|[\s|:-]*\|\s*\z/)
      next if line.include?("| What is accepted |")

      out << [:table, section, line_no, line]
      next
    end

    flush.call if bullet
    if prose
      prose[3] = "#{prose[3]}\n#{line}"
    else
      prose = [:prose, section, line_no, line]
    end
  end
  flush.call
  out
end

# The whole judgement, over a page's text and the axes the vector set declares.
# Returns [problems, rules] so both the gate and its self-test read one path.
def analyse(markdown, axes, exhaustive = [])
  problems = []
  limits   = []
  found    = grammar_section(markdown)

  if found.nil?
    return [["R5 the grammar section is not in the page: no line reads #{SECTION_HEADING.inspect}"], []]
  end

  body, first_line_no = found
  rules = []

  blocks(body, first_line_no).each do |kind, section, line_no, text|
    plain   = uncoded(text)
    markers = plain.scan(MARKER).flatten
    where   = "line #{line_no} (#{section})"

    # The limits subsection: bullets there are limits, not rules. They need no
    # axis and may not name one, and nothing else in this loop applies to them.
    if section == LIMITS_SUBSECTION
      if kind == :bullet
        limits << text
        unless markers.empty?
          problems << "R7 #{where}: a limit names a vector axis, which is a category " \
                      "error — a limit is what the set does NOT reach: " \
                      "#{text.lines.first.strip.inspect}"
        end
      end
      next
    end

    if kind == :prose && markers.empty?
      hits = NORMATIVE.select { |word| plain.downcase.include?(word) }
      unless hits.empty?
        problems << "R4 #{where}: prose states a rule (#{hits.join(', ')}) but is not a " \
                    "bullet or a table row, so no marker is required of it — move it into " \
                    "a rule, or give it its own marker: #{text.lines.first.strip.inspect}"
      end
      next
    end

    if markers.empty?
      problems << "R1 #{where}: no `<!-- vectors: … -->` marker on #{text.lines.first.strip.inspect}"
      next
    end

    if markers.length > 1
      problems << "R1 #{where}: #{markers.length} markers on one rule, which is ambiguous"
      next
    end

    named = markers.first.split(",").map(&:strip).reject(&:empty?)
    if named.empty?
      problems << "R1 #{where}: the marker names no axis"
      next
    end

    named.each do |axis|
      next if axes.include?(axis)

      problems << "R2 #{where}: names axis #{axis.inspect}, which token_vectors.rb does not " \
                  "have (it has: #{axes.join(', ')})"
    end

    universals = BYTE_UNIVERSAL.select { |word| plain.downcase.include?(word) }
    if !universals.empty? && (named & exhaustive).empty?
      problems << "R6 #{where}: quantifies over the byte domain " \
                  "(#{universals.join(', ')}) but names #{named.join(', ')}, and the " \
                  "vector set runs all 256 byte values only on " \
                  "#{exhaustive.empty? ? '(no axis at all)' : exhaustive.join(', ')} — " \
                  "a universal over a domain the set samples is the shape this gate " \
                  "exists for: #{text.lines.first.strip.inspect}"
    end

    rules << Rule.new(kind, section, line_no, text, named)
  end

  named_axes = rules.flat_map(&:axes).uniq
  (axes - named_axes).each do |axis|
    problems << "R3 axis #{axis.inspect} has vectors but no rule on the page names it — " \
                "either the page is missing the rule those vectors pin, or the axis is"
  end

  SUBSECTIONS.each do |section|
    next if rules.any? { |rule| rule.subsection == section }

    problems << "R5 subsection #{section} yielded no rule, so nothing in it is being checked"
  end

  if limits.empty?
    problems << "R7 subsection #{LIMITS_SUBSECTION} yielded no limit, so the page states " \
                "only what is true of the token and nothing about what it does not claim"
  end

  if rules.none? { |rule| NORMATIVE.any? { |word| uncoded(rule.text).downcase.include?(word) } }
    problems << "R5 not one rule uses the normative vocabulary R4 scans prose for, so that " \
                "scan has no live subject and cannot fail"
  end

  if rules.none? { |rule| BYTE_UNIVERSAL.any? { |word| uncoded(rule.text).downcase.include?(word) } }
    problems << "R5 not one rule uses the byte-domain vocabulary R6 scans for, so that arm " \
                "has no live subject and cannot fail — the page has stopped saying what " \
                "happens to the bytes it does not admit"
  end

  [problems, rules, limits]
end

def report(problems, rules, limits, axes, exhaustive)
  if problems.empty?
    puts "  Grammar coverage — #{rules.length} rules and #{limits.length} stated limits " \
         "on #{File.basename(PAGE)} across #{rules.map(&:subsection).uniq.length} " \
         "subsections, naming all #{axes.length} vector axes (#{axes.join(', ')}); " \
         "exhaustive over the byte domain: " \
         "#{exhaustive.empty? ? 'NO AXIS' : exhaustive.join(', ')} ✓"
    return 0
  end

  puts "  Grammar coverage — #{problems.length} problem(s) between " \
       "#{File.basename(PAGE)} and token_vectors.rb ✗"
  problems.each { |problem| puts "    #{problem}" }
  1
end

# ---------------------------------------------------------------------------
# Self-test: one fixture per rule, plus the vacuity arm and the ORIGINAL defect
# ---------------------------------------------------------------------------

GOOD_PAGE = <<~MARKDOWN
  # A page

  ## Rental token: the exact grammar

  Three programs read this token, and this section is where the grammar is decided.

  **Wire token**

  - At most 512 bytes. <!-- vectors: length -->
  - The signature is unpadded base64url. <!-- vectors: sig -->

  **Message**

  - Exactly six pipe-separated fields. <!-- vectors: count -->

  **Fields**

  | # | Field | What is accepted |
  |---|---|---|
  | 0 | tag | the bytes and nothing else <!-- vectors: tag --> |
  | 2 | resv | 1+ characters of A-Za-z0-9; every other byte value is refused <!-- vectors: charset --> |

  **What this section does not claim**

  - Nothing here says the three readers are the same program.

  ## Something else
MARKDOWN

GOOD_AXES       = %w[length sig count tag charset].freeze
GOOD_EXHAUSTIVE = %w[charset].freeze

def self_test
  arms = []

  arms << ["S1 a well-formed page is clean", lambda {
    problems, rules, _limits = analyse(GOOD_PAGE, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.empty? && rules.length == 5
  }]

  arms << ["S2 R1: a bullet with no marker fails", lambda {
    page = GOOD_PAGE.sub(" <!-- vectors: length -->", "")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.start_with?("R1") }
  }]

  arms << ["S3 R1: two markers on one rule fails", lambda {
    page = GOOD_PAGE.sub("<!-- vectors: length -->", "<!-- vectors: length --> <!-- vectors: sig -->")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.include?("2 markers on one rule") }
  }]

  arms << ["S4 R1: a table data row with no marker fails", lambda {
    page = GOOD_PAGE.sub(" <!-- vectors: tag -->", "")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.start_with?("R1") }
  }]

  arms << ["S5 R2: a marker naming an unknown axis fails", lambda {
    page = GOOD_PAGE.sub("<!-- vectors: sig -->", "<!-- vectors: signature -->")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.start_with?("R2") }
  }]

  arms << ["S6 R3: an axis no rule names fails", lambda {
    problems, = analyse(GOOD_PAGE, GOOD_AXES + ["bytes"], GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.start_with?("R3") && problem.include?("bytes") }
  }]

  arms << ["S7 R4: a rule smuggled into a paragraph fails", lambda {
    page = GOOD_PAGE.sub("this section is where the grammar is decided.",
                         "a token must carry the tag.")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.start_with?("R4") }
  }]

  arms << ["S8 R4: a paragraph with a marker is read as a rule", lambda {
    page = GOOD_PAGE.sub("this section is where the grammar is decided.",
                         "a token must carry the tag. <!-- vectors: tag -->")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.none? { |problem| problem.start_with?("R4") }
  }]

  arms << ["S9 R5: a missing section fails", lambda {
    page = GOOD_PAGE.sub(SECTION_HEADING, "## Something quite different")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.include?("the grammar section is not in the page") }
  }]

  arms << ["S10 R5: a subsection with no rule fails", lambda {
    page = GOOD_PAGE.sub("- Exactly six pipe-separated fields. <!-- vectors: count -->\n", "")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.include?("**Message** yielded no rule") }
  }]

  arms << ["S11 R5: rules with no normative vocabulary fail", lambda {
    page = GOOD_PAGE
           .sub("At most 512 bytes.", "The size is 512 bytes.")
           .sub("Exactly six pipe-separated fields.", "Six pipe-separated fields.")
           .sub("the bytes and nothing else", "the bytes")
           .sub("every other byte value is refused", "every other byte value is dropped")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.include?("no live subject") }
  }]

  arms << ["S13 a marker quoted inside a code span is prose, not a marker", lambda {
    page = GOOD_PAGE.sub("this section is where the grammar is decided.",
                         "each rule carries a `<!-- vectors: nosuchaxis -->` marker.")
    problems, rules, _limits = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.empty? && rules.length == 5
  }]

  arms << ["S14 R6: a byte-domain universal on a sampled axis fails", lambda {
    page = GOOD_PAGE.sub("<!-- vectors: charset -->", "<!-- vectors: tag -->")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.start_with?("R6") }
  }]

  arms << ["S15 R6: the same rule on an axis nothing exhausts fails", lambda {
    problems, = analyse(GOOD_PAGE, GOOD_AXES, [])
    problems.any? { |problem| problem.start_with?("R6") && problem.include?("no axis at all") }
  }]

  arms << ["S16 R5: rules with no byte-domain vocabulary fail", lambda {
    page = GOOD_PAGE.sub("every other byte value is refused", "everything else is refused")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.include?("byte-domain vocabulary") }
  }]

  arms << ["S17 R7: a section with no stated limits fails", lambda {
    page = GOOD_PAGE.sub("- Nothing here says the three readers are the same program.\n", "")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.include?("yielded no limit") }
  }]

  arms << ["S18 R7: a limit that names a vector axis fails", lambda {
    page = GOOD_PAGE.sub("same program.", "same program. <!-- vectors: tag -->")
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE)
    problems.any? { |problem| problem.start_with?("R7") && problem.include?("category error") }
  }]

  # T-201 rule 3 — THE ORIGINAL MOTIVATING DEFECT OF R6, in the bytes it
  # actually had. This is the `reservation_id` cell the grammar shipped with,
  # marker and all, planted back into the LIVE page: it passed R1-R5 for as
  # long as it existed while the three readers disagreed on 128 of the 256
  # single-byte cases, and R6 is the arm that had to redden on it.
  arms << ["S19 the original defect: the shipped reservation_id cell, live page", lambda {
    original = "| 2 | `reservation_id` | opaque, non-empty, any bytes but `\\|` and NUL — " \
               "a newline, a tab, a control character or multibyte UTF-8 all pass. No " \
               "reader constrains it further and none gates on it. " \
               "<!-- vectors: empty, bytes --> |\n"
    page = File.read(PAGE)
    marker = page.lines.find { |line| line.start_with?("| 3 | `iat`") }
    return false if marker.nil?

    planted = page.sub(marker, original + marker)
    problems, = analyse(planted, SkootiTokenVectors.axes, SkootiTokenVectors.exhaustive_axes)
    problems.any? { |problem| problem.start_with?("R6") && problem.include?("any bytes") }
  }]

  # T-201 rule 3 — the ORIGINAL motivating defect of R2, in the shape it
  # actually had: the live page states the signature rule, and the vector set is
  # the one that shipped before this gate existed, whose axes stop at `fresh`.
  arms << ["S12 the original defect: the live page's signature rule against the pre-sig axes", lambda {
    pre_sig_axes = %w[count empty tag int jti length fresh]
    problems, = analyse(File.read(PAGE), pre_sig_axes)
    problems.any? { |problem| problem.start_with?("R2") && problem.include?("\"sig\"") }
  }]

  failed = 0
  arms.each do |name, arm|
    ok = arm.call
    failed += 1 unless ok
    puts "  #{ok ? 'PASS' : 'FAIL'}  #{name}"
  end

  puts "  self-test: #{arms.length - failed} passed, #{failed} failed"
  failed.zero? ? 0 : 1
end

if ARGV.include?("--self-test")
  exit self_test
else
  axes       = SkootiTokenVectors.axes
  exhaustive = SkootiTokenVectors.exhaustive_axes
  problems, rules, limits = analyse(File.read(PAGE), axes, exhaustive)
  exit report(problems, rules, limits, axes, exhaustive)
end
