# frozen_string_literal: true

# K-1846: an example every one of whose expectations sits on a conditional path
# reports green when none of them runs. Three shapes carry that, and all three
# were live in this repository: a `rescue` clause, an `if`/`case` branch, and a
# stub implementation block (`allow(x).to receive(:y) do … end`).
#
# Three shapes are NOT flagged, because none of them can pass with nothing
# asserted:
#
#   * a `rescue` clause protecting a body that ends in `raise` — the clause runs
#     or the example errors, so catching IS the assertion.
#   * a block on a MESSAGE expectation (`expect(x).to receive(:y) do`), which
#     asserts the call that runs the block.
#   * an example that calls `skip` or `pending` — it announces that it did not
#     run instead of passing.
#
# What it cannot see, because it reads source and never runs it: an expectation
# inside a helper the example calls, and an example carrying no `expect` at all
# — a different emptiness, and not this one.
#
# Corpus: every tracked `*_spec.rb`, parsed rather than loaded, the way
# `no_ruby_warnings_spec.rb` beside it reads its own.

require "open3"

CONDEXP_REPO_ROOT = File.expand_path("../..", __dir__)
CONDEXP_EXAMPLE   = %i[it specify example].freeze
CONDEXP_STUB      = %i[receive receive_messages and_return and_invoke and_yield].freeze
CONDEXP_ASSERTING = %i[expect expect_any_instance_of].freeze
CONDEXP_ANNOUNCE  = %i[skip pending].freeze

CONDEXP_TRACKED, CONDEXP_GIT = Open3.capture2("git", "-C", CONDEXP_REPO_ROOT, "ls-files", "-z", "*_spec.rb")
raise "git ls-files failed in #{CONDEXP_REPO_ROOT}" unless CONDEXP_GIT.success?

CONDEXP_FILES = CONDEXP_TRACKED.split("\0").reject(&:empty?).sort.freeze

def condexp_node?(node) = node.is_a?(RubyVM::AbstractSyntaxTree::Node)

# The method name of a call node, wherever it sits among the children.
def condexp_mid(node) = node.children.find { |c| c.is_a?(Symbol) }

def condexp_calls?(node, names)
  return false unless condexp_node?(node)
  return true if %i[FCALL CALL VCALL].include?(node.type) && names.include?(condexp_mid(node))

  node.children.any? { |c| condexp_calls?(c, names) }
end

# A body whose last statement raises makes its rescue clauses unconditional.
def condexp_raises?(body)
  return false unless condexp_node?(body)

  last = body.type == :BLOCK ? body.children.compact.last : body
  condexp_node?(last) && last.type == :FCALL && condexp_mid(last) == :raise
end

# A stub implementation block runs only if the stubbed method is called — unless
# the same call asserts that it is.
def condexp_stub_block?(call)
  condexp_calls?(call, CONDEXP_STUB) && !condexp_calls?(call, CONDEXP_ASSERTING)
end

# Every `expect` under this node, as [line, conditional?].
def condexp_expects(node, guarded, out)
  return unless condexp_node?(node)

  case node.type
  when :RESCUE
    body, resbody, els = node.children
    condexp_expects(body, guarded, out)
    condexp_expects(resbody, guarded || !condexp_raises?(body), out)
    condexp_expects(els, guarded, out)
    return
  when :IF, :UNLESS, :CASE, :CASE2, :CASE3, :WHEN, :IN
    cond, *branches = node.children
    condexp_expects(cond, guarded, out)
    branches.each { |b| condexp_expects(b, true, out) }
    return
  when :ITER
    call, scope = node.children
    condexp_expects(call, guarded, out)
    condexp_expects(scope, guarded || condexp_stub_block?(call), out)
    return
  when :FCALL
    out << [node.first_lineno, guarded] if condexp_mid(node) == :expect
  end

  node.children.each { |c| condexp_expects(c, guarded, out) }
end

def condexp_walk(node, out)
  return out unless condexp_node?(node)

  call, scope = node.children
  if node.type == :ITER && condexp_node?(call) && call.type == :FCALL &&
     CONDEXP_EXAMPLE.include?(condexp_mid(call)) && !condexp_calls?(scope, CONDEXP_ANNOUNCE)
    found = []
    condexp_expects(scope, false, found)
    out << [node.first_lineno, found.length] if found.any? && found.all? { |(_, guarded)| guarded }
  end

  node.children.each { |child| condexp_walk(child, out) }
  out
end

# Every example in this source that asserts only under a condition, as
# [line, expectation count].
def condexp_offenders(src) = condexp_walk(RubyVM::AbstractSyntaxTree.parse(src), [])

RSpec.describe "no example asserts only under a condition (K-1846)" do
  it "reads every tracked spec file, so a green run means something" do
    expect(CONDEXP_FILES.length).to be > 150
  end

  it "finds no example whose every expectation is conditional" do
    report = CONDEXP_FILES.flat_map do |rel|
      src = File.read(File.join(CONDEXP_REPO_ROOT, rel))
      begin
        condexp_offenders(src).map { |(line, n)| "  #{rel}:#{line} — #{n} expectation(s), every one conditional" }
      rescue SyntaxError => e
        ["  #{rel}: does not parse — #{e.message.lines.first.to_s.strip}"]
      end
    end

    expect(report).to be_empty, lambda {
      "#{report.length} example(s) assert nothing unless the condition holds. Assert the raise " \
      "itself — `expect { … }.to raise_error(Klass) { |e| … }` — or capture what the stub received " \
      "and assert it after the call.\n" + report.join("\n")
    }
  end

  describe "the shapes it flags, and the ones it does not" do
    it "FLAGS a begin/rescue whose expectations are all in the rescue clause" do
      src = <<~RUBY
        it "x" do
          thing.call
        rescue Boom => e
          expect(e.code).to eq("boom")
        end
      RUBY
      expect(condexp_offenders(src)).to eq([[1, 1]])
    end

    it "FLAGS expectations inside a stub implementation block" do
      src = <<~RUBY
        it "x" do
          allow(idp).to receive(:issue) do |role:|
            expect(role).to eq("customer")
            "token"
          end
          subject.call
        end
      RUBY
      expect(condexp_offenders(src)).to eq([[1, 1]])
    end

    it "FLAGS an expectation reachable only through an if" do
      expect(condexp_offenders(%(it "x" do\n  expect(a).to eq(1) if ready?\nend\n))).to eq([[1, 1]])
    end

    it "ALLOWS raise_error with a block — the raise itself is asserted" do
      src = <<~RUBY
        it "x" do
          expect { thing.call }.to raise_error(Boom) { |e| expect(e.code).to eq("boom") }
        end
      RUBY
      expect(condexp_offenders(src)).to be_empty
    end

    it "ALLOWS a block on a message expectation, which asserts the call" do
      src = <<~RUBY
        it "x" do
          expect(idp).to receive(:issue) { |role:| expect(role).to eq("customer") }
          subject.call
        end
      RUBY
      expect(condexp_offenders(src)).to be_empty
    end

    it "ALLOWS a rescue clause protecting a body that raises" do
      src = <<~RUBY
        it "x" do
          begin
            raise klass, "x"
          rescue Base => caught
            expect(caught).to be_a(klass)
          end
        end
      RUBY
      expect(condexp_offenders(src)).to be_empty
    end

    it "ALLOWS an example that skips the branch it cannot assert" do
      src = <<~RUBY
        it "x" do
          if wrong_nonce?
            expect(verify).to be(false)
          else
            skip "the nonce happens to satisfy the difficulty"
          end
        end
      RUBY
      expect(condexp_offenders(src)).to be_empty
    end

    it "ALLOWS an expectation after a closed begin/rescue" do
      src = <<~RUBY
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
      expect(condexp_offenders(src)).to be_empty
    end

    it "ALLOWS a stub block whose assertion sits outside it" do
      src = <<~RUBY
        it "x" do
          allow(idp).to receive(:issue) { |role:| seen = role }
          subject.call
          expect(seen).to eq("customer")
        end
      RUBY
      expect(condexp_offenders(src)).to be_empty
    end

    it "says nothing about an example with no expectation at all" do
      expect(condexp_offenders(%(it "x" do\n  subject.call\nend\n))).to be_empty
    end
  end
end
