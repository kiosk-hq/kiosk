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
#   R8  A rule that states the SCALAR RANGE — the half of the signature RFC
#       8032 bounds by the group order — names an axis the vector set respells
#       the scalar on. R6's shape, on the other half of the signature: "the
#       scalar is below the group order" reads identically on this page whether
#       a vector can reach it or not, and an axis that only respells the 64
#       bytes in base64 cannot. So a rule making this claim is asked for an
#       axis on which some vector moves the scalar itself.
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

require_relative 'token_vectors'

PAGE = File.expand_path('../RENTAL_TOKEN.md', __dir__)

# The section this gate reads. Named by its heading so a renamed heading is a
# loud failure rather than a silent empty scan.
SECTION_HEADING = '## Rental token: the exact grammar'

# The bold lines that open a RULE subsection inside it. Each has to yield a rule.
SUBSECTIONS = ['**Wire token**', '**Message**', '**Fields**'].freeze

# The bold line that opens the LIMITS subsection. Its bullets are limits, not
# rules: R1 does not ask them for an axis and R6 does not read them, because a
# limit's whole job is to say what the set does NOT reach. A marker inside one
# is a category error and fails.
LIMITS_SUBSECTION = '**What this section does not claim**'

# Normative vocabulary. A paragraph using any of these is stating a rule, and a
# rule belongs in a bullet or a table row where R1 can see it. Matched
# case-insensitively.
NORMATIVE = [
  'must', 'may not', 'at most', 'at least', 'exactly',
  'and nothing else', 'is refused', 'are refused',
  'is rejected', 'are rejected', 'is a refusal'
].freeze

# Vocabulary that states a rule about the signature's SCALAR — the second 32
# bytes, which RFC 8032 decodes as a number below the group order. A rule using
# any of these is claiming the range is held, so R8 asks it to name an axis the
# set actually respells the scalar on. Matched case-insensitively, after code
# spans are dropped, exactly as BYTE_UNIVERSAL is.
SCALAR_RANGE = ['scalar', 'group order'].freeze

# Vocabulary that quantifies over the BYTE DOMAIN, or denies that anything
# further constrains a field. A rule using any of these is making a claim about
# all 256 byte values whether it says the number or not, so R6 asks it to name
# an axis that has been run over all 256. Matched case-insensitively, after
# code spans are dropped — the original defect spelled its delimiter in
# backticks and would otherwise have read as "any bytes but \| and NUL".
BYTE_UNIVERSAL = [
  'any byte', 'any bytes', 'every byte', 'all bytes', 'byte value',
  'no reader constrains', 'none gates on it', 'nothing further'
].freeze

MARKER = /<!--\s*vectors:\s*([^>]*?)\s*-->/

# An inline code span. A marker written INSIDE one is the page quoting the
# syntax to a reader, not applying it — the paragraph that explains this gate
# spells a marker out, and without this it would read as claiming an axis. Code
# spans are dropped before both the marker scan and the vocabulary scan.
CODE_SPAN = /`[^`]*`/

Rule = Struct.new(:kind, :subsection, :line_no, :text, :axes)

def uncoded(text)
  text.gsub(CODE_SPAN, ' ')
end

# Pull the grammar section out of a page. Returns its lines, or nil when the
# heading is not there.
def grammar_section(markdown)
  lines = markdown.lines.map(&:chomp)
  start = lines.index { |line| line.strip == SECTION_HEADING }
  return nil if start.nil?

  rest = lines[(start + 1)..] || []
  stop = rest.index { |line| line.start_with?('## ') }
  body = stop.nil? ? rest : rest[0...stop]
  [body, start + 2] # 1-based line number of the first body line
end

def mentions(text, words)
  words.select { |word| uncoded(text).downcase.include?(word) }
end

def first_line(text)
  text.lines.first.strip.inspect
end

# A vocabulary no rule uses is a scan with no live subject, with the problem that says so.
VACUITY = {
  NORMATIVE => 'R5 not one rule uses the normative vocabulary R4 scans prose for, so that ' \
               'scan has no live subject and cannot fail',
  BYTE_UNIVERSAL => 'R5 not one rule uses the byte-domain vocabulary R6 scans for, so that arm ' \
                    'has no live subject and cannot fail — the page has stopped saying what ' \
                    'happens to the bytes it does not admit',
  SCALAR_RANGE => 'R8 not one rule uses the scalar vocabulary R8 scans for, so that arm has ' \
                  'no live subject and cannot fail — the page has stopped stating the range ' \
                  "the signature's second half is decoded in"
}.freeze

# The whole judgement, over a page's text and the axes the vector set declares.
# #run returns [problems, rules, limits], so the gate and its self-test read one path.
class Analysis
  # Splits the section into blocks. A bullet block is its "- " line plus every
  # indented continuation line; a table data row is one line; everything else
  # accumulates into prose blocks. #blocks returns [kind, subsection, line_no, text].
  class BlockSplitter
    TABLE_FRAME = /\A\|[\s|:-]*\|\s*\z/
    TABLE_HEADER = '| What is accepted |'

    def initialize
      @out     = []
      @section = '(before any subsection)'
      @prose   = nil
      @bullet  = nil
    end

    def blocks(body, first_line_no)
      body.each_with_index { |line, index| feed(line, first_line_no + index) }
      flush
      @out
    end

    private

    def feed(line, line_no)
      stripped = line.strip
      if stripped.empty? then flush
      elsif heading?(stripped) then open_section(stripped)
      elsif line.start_with?('- ') then open_bullet(line, line_no)
      elsif continuation?(line) then @bullet[3] = "#{@bullet[3]}\n#{line}"
      elsif line.start_with?('|') then table_row(line, line_no)
      else prose_line(line, line_no)
      end
    end

    def heading?(stripped)
      SUBSECTIONS.include?(stripped) || stripped == LIMITS_SUBSECTION
    end

    def continuation?(line)
      !@bullet.nil? && line.start_with?('  ')
    end

    def flush
      @out << @bullet if @bullet
      @out << @prose  if @prose
      @bullet = nil
      @prose  = nil
    end

    def open_section(heading)
      flush
      @section = heading
    end

    def open_bullet(line, line_no)
      flush
      @bullet = [:bullet, @section, line_no, line]
    end

    # Skips the header row and the --- separator row of a table.
    def table_row(line, line_no)
      flush
      return if line.match?(TABLE_FRAME) || line.include?(TABLE_HEADER)

      @out << [:table, @section, line_no, line]
    end

    def prose_line(line, line_no)
      flush if @bullet
      if @prose
        @prose[3] = "#{@prose[3]}\n#{line}"
      else
        @prose = [:prose, @section, line_no, line]
      end
    end
  end

  # The checks over the whole page, after every block is read: R3, R5 and R7.
  module PageChecks
    private

    def check_page
      check_unnamed_axes
      check_empty_subsections
      check_limits_stated
      check_vocabulary_live
    end

    def check_unnamed_axes
      (axes - rules.flat_map(&:axes).uniq).each do |axis|
        problems << "R3 axis #{axis.inspect} has vectors but no rule on the page names it — " \
                    'either the page is missing the rule those vectors pin, or the axis is'
      end
    end

    def check_empty_subsections
      SUBSECTIONS.each do |section|
        next if rules.any? { |rule| rule.subsection == section }

        problems << "R5 subsection #{section} yielded no rule, so nothing in it is being checked"
      end
    end

    def check_limits_stated
      return unless limits.empty?

      problems << "R7 subsection #{LIMITS_SUBSECTION} yielded no limit, so the page states " \
                  'only what is true of the token and nothing about what it does not claim'
    end

    def check_vocabulary_live
      VACUITY.each { |words, problem| problems << problem unless vocabulary_used?(words) }
    end

    def vocabulary_used?(words)
      rules.any? { |rule| mentions(rule.text, words).any? }
    end
  end

  include PageChecks

  attr_reader :problems, :rules, :limits, :axes, :exhaustive, :scalar

  def initialize(axes, exhaustive, scalar)
    @axes       = axes
    @exhaustive = exhaustive
    @scalar     = scalar
    @problems   = []
    @rules      = []
    @limits     = []
  end

  def run(markdown)
    found = grammar_section(markdown)
    return [["R5 the grammar section is not in the page: no line reads #{SECTION_HEADING.inspect}"], []] if found.nil?

    BlockSplitter.new.blocks(*found).each { |kind, section, line_no, text| check_block(kind, section, line_no, text) }
    check_page
    [problems, rules, limits]
  end

  private

  def check_block(kind, section, line_no, text)
    markers = uncoded(text).scan(MARKER).flatten
    where   = "line #{line_no} (#{section})"
    if section == LIMITS_SUBSECTION
      check_limit(kind, where, text, markers)
    elsif kind == :prose && markers.empty?
      check_prose(where, text)
    else
      named = marked_axes(where, text, markers)
      check_rule(Rule.new(kind, section, line_no, text, named), where) if named
    end
  end

  # Bullets in the limits subsection are limits, not rules. They need no axis and may not name one.
  def check_limit(kind, where, text, markers)
    return unless kind == :bullet

    limits << text
    return if markers.empty?

    problems << "R7 #{where}: a limit names a vector axis, which is a category " \
                'error — a limit is what the set does NOT reach: ' \
                "#{first_line(text)}"
  end

  def check_prose(where, text)
    hits = mentions(text, NORMATIVE)
    return if hits.empty?

    problems << "R4 #{where}: prose states a rule (#{hits.join(', ')}) but is not a " \
                'bullet or a table row, so no marker is required of it — move it into ' \
                "a rule, or give it its own marker: #{first_line(text)}"
  end

  # The axes the one marker on a rule names, or nil after recording why there are none.
  def marked_axes(where, text, markers)
    if markers.empty?
      problems << "R1 #{where}: no `<!-- vectors: … -->` marker on #{first_line(text)}"
    elsif markers.length > 1
      problems << "R1 #{where}: #{markers.length} markers on one rule, which is ambiguous"
    else
      named = markers.first.split(',').map(&:strip).reject(&:empty?)
      return named unless named.empty?

      problems << "R1 #{where}: the marker names no axis"
    end
    nil
  end

  def axes_or_none(list)
    list.empty? ? '(no axis at all)' : list.join(', ')
  end

  def check_rule(rule, where)
    check_known_axes(rule, where)
    check_scalar_rule(rule, where)
    check_universal_rule(rule, where)
    rules << rule
  end

  def check_known_axes(rule, where)
    rule.axes.each do |axis|
      next if axes.include?(axis)

      problems << "R2 #{where}: names axis #{axis.inspect}, which token_vectors.rb does not " \
                  "have (it has: #{axes.join(', ')})"
    end
  end

  def check_scalar_rule(rule, where)
    scalars = mentions(rule.text, SCALAR_RANGE)
    return if scalars.empty? || rule.axes.intersect?(scalar)

    problems << "R8 #{where}: states a rule about the signature scalar " \
                "(#{scalars.join(', ')}) but names #{rule.axes.join(', ')}, and the vector " \
                'set respells the scalar only on ' \
                "#{axes_or_none(scalar)} — a claim " \
                'about which 64 bytes are a signature that no vector can reach: ' \
                "#{first_line(rule.text)}"
  end

  def check_universal_rule(rule, where)
    universals = mentions(rule.text, BYTE_UNIVERSAL)
    return if universals.empty? || rule.axes.intersect?(exhaustive)

    problems << "R6 #{where}: quantifies over the byte domain " \
                "(#{universals.join(', ')}) but names #{rule.axes.join(', ')}, and the " \
                'vector set runs all 256 byte values only on ' \
                "#{axes_or_none(exhaustive)} — " \
                'a universal over a domain the set samples is the shape this gate ' \
                "exists for: #{first_line(rule.text)}"
  end
end

def analyse(markdown, axes, exhaustive = [], scalar = [])
  Analysis.new(axes, exhaustive, scalar).run(markdown)
end

def or_no_axis(list)
  list.empty? ? 'NO AXIS' : list.join(', ')
end

def report(analysis)
  return report_problems(analysis.problems) unless analysis.problems.empty?

  puts "  Grammar coverage — #{counts(analysis)}, naming all #{analysis.axes.length} vector axes " \
       "(#{analysis.axes.join(', ')}); exhaustive over the byte domain: #{or_no_axis(analysis.exhaustive)}; " \
       "scalar respelt on: #{or_no_axis(analysis.scalar)} ✓"
  0
end

def counts(analysis)
  rules = analysis.rules
  "#{rules.length} rules and #{analysis.limits.length} stated limits on #{File.basename(PAGE)} " \
    "across #{rules.map(&:subsection).uniq.length} subsections"
end

def report_problems(problems)
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
  - Its second half is a scalar below the group order. <!-- vectors: sig -->

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
GOOD_SCALAR     = %w[sig].freeze

SELF_TEST_ARMS = [
  ['S1 a well-formed page is clean', lambda {
    problems, rules, _limits = analyse(GOOD_PAGE, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.empty? && rules.length == 6
  }],

  ['S2 R1: a bullet with no marker fails', lambda {
    page = GOOD_PAGE.sub(' <!-- vectors: length -->', '')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R1') }
  }],

  ['S3 R1: two markers on one rule fails', lambda {
    page = GOOD_PAGE.sub('<!-- vectors: length -->', '<!-- vectors: length --> <!-- vectors: sig -->')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.include?('2 markers on one rule') }
  }],

  ['S4 R1: a table data row with no marker fails', lambda {
    page = GOOD_PAGE.sub(' <!-- vectors: tag -->', '')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R1') }
  }],

  ['S5 R2: a marker naming an unknown axis fails', lambda {
    page = GOOD_PAGE.sub('<!-- vectors: sig -->', '<!-- vectors: signature -->')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R2') }
  }],

  ['S6 R3: an axis no rule names fails', lambda {
    problems, = analyse(GOOD_PAGE, GOOD_AXES + ['bytes'], GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R3') && problem.include?('bytes') }
  }],

  ['S7 R4: a rule smuggled into a paragraph fails', lambda {
    page = GOOD_PAGE.sub('this section is where the grammar is decided.',
                         'a token must carry the tag.')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R4') }
  }],

  ['S8 R4: a paragraph with a marker is read as a rule', lambda {
    page = GOOD_PAGE.sub('this section is where the grammar is decided.',
                         'a token must carry the tag. <!-- vectors: tag -->')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.none? { |problem| problem.start_with?('R4') }
  }],

  ['S9 R5: a missing section fails', lambda {
    page = GOOD_PAGE.sub(SECTION_HEADING, '## Something quite different')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.include?('the grammar section is not in the page') }
  }],

  ['S10 R5: a subsection with no rule fails', lambda {
    page = GOOD_PAGE.sub("- Exactly six pipe-separated fields. <!-- vectors: count -->\n", '')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.include?('**Message** yielded no rule') }
  }],

  ['S11 R5: rules with no normative vocabulary fail', lambda {
    page = GOOD_PAGE
           .sub('At most 512 bytes.', 'The size is 512 bytes.')
           .sub('Exactly six pipe-separated fields.', 'Six pipe-separated fields.')
           .sub('the bytes and nothing else', 'the bytes')
           .sub('every other byte value is refused', 'every other byte value is dropped')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.include?('no live subject') }
  }],

  ['S13 a marker quoted inside a code span is prose, not a marker', lambda {
    page = GOOD_PAGE.sub('this section is where the grammar is decided.',
                         'each rule carries a `<!-- vectors: nosuchaxis -->` marker.')
    problems, rules, _limits = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.empty? && rules.length == 6
  }],

  ['S14 R6: a byte-domain universal on a sampled axis fails', lambda {
    page = GOOD_PAGE.sub('<!-- vectors: charset -->', '<!-- vectors: tag -->')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R6') }
  }],

  ['S15 R6: the same rule on an axis nothing exhausts fails', lambda {
    problems, = analyse(GOOD_PAGE, GOOD_AXES, [], GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R6') && problem.include?('no axis at all') }
  }],

  ['S16 R5: rules with no byte-domain vocabulary fail', lambda {
    page = GOOD_PAGE.sub('every other byte value is refused', 'everything else is refused')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.include?('byte-domain vocabulary') }
  }],

  ['S17 R7: a section with no stated limits fails', lambda {
    page = GOOD_PAGE.sub("- Nothing here says the three readers are the same program.\n", '')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.include?('yielded no limit') }
  }],

  ['S18 R7: a limit that names a vector axis fails', lambda {
    page = GOOD_PAGE.sub('same program.', 'same program. <!-- vectors: tag -->')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.start_with?('R7') && problem.include?('category error') }
  }],

  # R6's motivating defect: an earlier `reservation_id` cell, planted into the
  # live page. It passes R1-R5 while the three readers disagree on 128 of the
  # 256 single-byte cases; R6 must redden on it.
  ['S19 the original defect: the shipped reservation_id cell, live page', lambda {
    original = '| 2 | `reservation_id` | opaque, non-empty, any bytes but `\\|` and NUL — ' \
               'a newline, a tab, a control character or multibyte UTF-8 all pass. No ' \
               'reader constrains it further and none gates on it. ' \
               "<!-- vectors: empty, bytes --> |\n"
    page = File.read(PAGE)
    marker = page.lines.find { |line| line.start_with?('| 3 | `iat`') }
    return false if marker.nil?

    planted = page.sub(marker, original + marker)
    problems, = analyse(planted, SkootiTokenVectors.axes, SkootiTokenVectors.exhaustive_axes,
                        SkootiTokenVectors.scalar_axes)
    problems.any? { |problem| problem.start_with?('R6') && problem.include?('any bytes') }
  }],

  # R2's motivating defect: the live page's signature rule against a vector set
  # whose axes stop at `fresh`.
  ["S12 the original defect: the live page's signature rule against the pre-sig axes", lambda {
    pre_sig_axes = %w[count empty tag int jti length fresh]
    problems, = analyse(File.read(PAGE), pre_sig_axes)
    problems.any? { |problem| problem.start_with?('R2') && problem.include?('"sig"') }
  }],

  ['S20 R8: a scalar rule on an axis nothing respells the scalar on fails', lambda {
    problems, = analyse(GOOD_PAGE, GOOD_AXES, GOOD_EXHAUSTIVE, ['count'])
    problems.any? { |problem| problem.start_with?('R8') && problem.include?('scalar') }
  }],

  ['S21 R8: a page that states no scalar rule fails the vacuity arm', lambda {
    page = GOOD_PAGE.sub("- Its second half is a scalar below the group order. <!-- vectors: sig -->\n", '')
    problems, = analyse(page, GOOD_AXES, GOOD_EXHAUSTIVE, GOOD_SCALAR)
    problems.any? { |problem| problem.include?('no live subject and cannot fail — the page has stopped stating the range') }
  }],

  # R8's motivating defect: the live page's scalar rule against a vector set
  # whose `sig` vectors only respell the base64 of fixed 64 bytes, so none
  # moves the scalar. R8 must redden on it.
  ["S22 the original defect: the live page's scalar rule against a set that respells no scalar", lambda {
    problems, = analyse(File.read(PAGE), SkootiTokenVectors.axes,
                        SkootiTokenVectors.exhaustive_axes, [])
    problems.any? { |problem| problem.start_with?('R8') && problem.include?('no axis at all') }
  }]
].freeze

def self_test
  failed = SELF_TEST_ARMS.count do |name, arm|
    ok = arm.call
    puts "  #{ok ? 'PASS' : 'FAIL'}  #{name}"
    !ok
  end

  puts "  self-test: #{SELF_TEST_ARMS.length - failed} passed, #{failed} failed"
  failed.zero? ? 0 : 1
end

if ARGV.include?('--self-test')
  exit self_test
else
  analysis = Analysis.new(SkootiTokenVectors.axes, SkootiTokenVectors.exhaustive_axes,
                          SkootiTokenVectors.scalar_axes)
  analysis.run(File.read(PAGE))
  exit report(analysis)
end
