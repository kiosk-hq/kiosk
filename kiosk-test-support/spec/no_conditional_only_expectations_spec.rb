# frozen_string_literal: true

# An example whose every expectation sits on a conditional path reports green
# when none of them runs. Three shapes do this: a `rescue` clause, an `if` or
# `case` branch, and a stub implementation block
# (`allow(x).to receive(:y) do … end`).
#
# Three shapes are NOT flagged, because none of them can pass with nothing
# asserted:
#
#   * a `rescue` clause protecting a body that ends in `raise`: the clause runs
#     or the example errors, so catching IS the assertion.
#   * a block on a MESSAGE expectation (`expect(x).to receive(:y) do`), which
#     asserts the call that runs the block.
#   * an example that calls `skip` or `pending`: it announces that it did not
#     run instead of passing.
#
# It reads source and never runs it, so it cannot see an expectation inside a
# helper the example calls. An example with no `expect` at all is a different
# emptiness and is not reported here.
#
# Corpus: every tracked `*_spec.rb`, parsed rather than loaded.

require 'open3'

module ConditionalExpectations
  REPO_ROOT = File.expand_path('../..', __dir__)
  EXAMPLE   = %i[it specify example].freeze
  STUB      = %i[receive receive_messages and_return and_invoke and_yield].freeze
  ASSERTING = %i[expect expect_any_instance_of].freeze
  ANNOUNCE  = %i[skip pending].freeze
  BRANCHING = %i[IF UNLESS CASE CASE2 CASE3 WHEN IN].freeze

  module_function

  def tracked_specs
    out, status = Open3.capture2('git', '-C', REPO_ROOT, 'ls-files', '-z', '*_spec.rb')
    raise "git ls-files failed in #{REPO_ROOT}" unless status.success?

    out.split("\0").reject(&:empty?).sort
  end

  def node?(node) = node.is_a?(RubyVM::AbstractSyntaxTree::Node)

  # The method name of a call node, wherever it sits among the children.
  def mid(node) = node.children.find { |child| child.is_a?(Symbol) }

  def calls?(node, names)
    return false unless node?(node)
    return true if %i[FCALL CALL VCALL].include?(node.type) && names.include?(mid(node))

    node.children.any? { |child| calls?(child, names) }
  end

  # A body whose last statement raises makes its rescue clauses unconditional.
  def raises?(body)
    return false unless node?(body)

    last = body.type == :BLOCK ? body.children.compact.last : body
    node?(last) && last.type == :FCALL && mid(last) == :raise
  end

  # A stub implementation block runs only if the stubbed method is called,
  # unless the same call asserts that it is.
  def stub_block?(call) = calls?(call, STUB) && !calls?(call, ASSERTING)

  # Every `expect` under this node, as [line, conditional?].
  def expects(node, guarded, out)
    return unless node?(node)

    case node.type
    when :RESCUE then rescue_expects(node, guarded, out)
    when *BRANCHING then branch_expects(node, guarded, out)
    when :ITER then iter_expects(node, guarded, out)
    else plain_expects(node, guarded, out)
    end
  end

  def plain_expects(node, guarded, out)
    out << [node.first_lineno, guarded] if node.type == :FCALL && mid(node) == :expect
    node.children.each { |child| expects(child, guarded, out) }
  end

  def rescue_expects(node, guarded, out)
    body, resbody, els = node.children
    expects(body, guarded, out)
    expects(resbody, guarded || !raises?(body), out)
    expects(els, guarded, out)
  end

  def branch_expects(node, guarded, out)
    cond, *branches = node.children
    expects(cond, guarded, out)
    branches.each { |branch| expects(branch, true, out) }
  end

  def iter_expects(node, guarded, out)
    call, scope = node.children
    expects(call, guarded, out)
    expects(scope, guarded || stub_block?(call), out)
  end

  # An `it`/`specify`/`example` block that does not skip.
  def example?(node)
    call, scope = node.children
    node.type == :ITER && node?(call) && call.type == :FCALL && EXAMPLE.include?(mid(call)) && !calls?(scope, ANNOUNCE)
  end

  def walk(node, out)
    return out unless node?(node)

    record_example(node, out) if example?(node)
    node.children.each { |child| walk(child, out) }
    out
  end

  def record_example(node, out)
    found = []
    expects(node.children[1], false, found)
    out << [node.first_lineno, found.length] if found.any? && found.all? { |(_, guarded)| guarded }
  end

  # Every example in this source that asserts only under a condition, as
  # [line, expectation count].
  def offenders(src) = walk(RubyVM::AbstractSyntaxTree.parse(src), [])

  # Report lines for one tracked spec file.
  def report(rel)
    offenders(File.read(File.join(REPO_ROOT, rel))).map do |(line, count)|
      "  #{rel}:#{line} — #{count} expectation(s), every one conditional"
    end
  rescue SyntaxError => e
    ["  #{rel}: does not parse — #{e.message.lines.first.to_s.strip}"]
  end

  FILES = tracked_specs.freeze
end

# Example sources for the shapes the check flags and the ones it allows.
module ConditionalExpectationFixtures
  FLAGGED = {
    'FLAGS a begin/rescue whose expectations are all in the rescue clause' => <<~RUBY,
      it "x" do
        thing.call
      rescue Boom => e
        expect(e.code).to eq("boom")
      end
    RUBY
    'FLAGS expectations inside a stub implementation block' => <<~RUBY,
      it "x" do
        allow(idp).to receive(:issue) do |role:|
          expect(role).to eq("customer")
          "token"
        end
        subject.call
      end
    RUBY
    'FLAGS an expectation reachable only through an if' => %(it "x" do\n  expect(a).to eq(1) if ready?\nend\n)
  }.freeze

  ALLOWED = {
    'ALLOWS raise_error with a block — the raise itself is asserted' => <<~RUBY,
      it "x" do
        expect { thing.call }.to raise_error(Boom) { |e| expect(e.code).to eq("boom") }
      end
    RUBY
    'ALLOWS a block on a message expectation, which asserts the call' => <<~RUBY,
      it "x" do
        expect(idp).to receive(:issue) { |role:| expect(role).to eq("customer") }
        subject.call
      end
    RUBY
    'ALLOWS a rescue clause protecting a body that raises' => <<~RUBY,
      it "x" do
        begin
          raise klass, "x"
        rescue Base => caught
          expect(caught).to be_a(klass)
        end
      end
    RUBY
    'ALLOWS an example that skips the branch it cannot assert' => <<~RUBY,
      it "x" do
        if wrong_nonce?
          expect(verify).to be(false)
        else
          skip "the nonce happens to satisfy the difficulty"
        end
      end
    RUBY
    'ALLOWS an expectation after a closed begin/rescue' => <<~RUBY,
      it "x" do
        caught = nil
        begin
          thing.call
        rescue Boom => e
          caught = e
        end
        expect(caught.code).to eq("boom")
      end
    RUBY
    'ALLOWS a stub block whose assertion sits outside it' => <<~RUBY,
      it "x" do
        allow(idp).to receive(:issue) { |role:| seen = role }
        subject.call
        expect(seen).to eq("customer")
      end
    RUBY
    'says nothing about an example with no expectation at all' => %(it "x" do\n  subject.call\nend\n)
  }.freeze
end

RSpec.describe 'no example asserts only under a condition (K-1846)' do
  it 'reads every tracked spec file, so a green run means something' do
    expect(ConditionalExpectations::FILES.length).to be > 150
  end

  it 'finds no example whose every expectation is conditional' do
    report = ConditionalExpectations::FILES.flat_map { |rel| ConditionalExpectations.report(rel) }

    expect(report).to be_empty, lambda {
      "#{report.length} example(s) assert nothing unless the condition holds. Assert the raise " \
      'itself — `expect { … }.to raise_error(Klass) { |e| … }` — or capture what the stub received ' \
      "and assert it after the call.\n" + report.join("\n")
    }
  end

  describe 'the shapes the conditional-expectation check flags' do
    ConditionalExpectationFixtures::FLAGGED.each do |label, src|
      it label do
        expect(ConditionalExpectations.offenders(src)).to eq([[1, 1]])
      end
    end
  end

  describe 'the shapes the conditional-expectation check does not flag' do
    ConditionalExpectationFixtures::ALLOWED.each do |label, src|
      it label do
        expect(ConditionalExpectations.offenders(src)).to be_empty
      end
    end
  end
end
