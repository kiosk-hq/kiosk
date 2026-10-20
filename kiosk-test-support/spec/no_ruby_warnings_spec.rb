# frozen_string_literal: true

# Parses every tracked `.rb` and `.rake` file in warning mode. A dead binding
# (a variable assigned and never read) is a defect that Ruby names at parse
# time; nothing else in the repository runs Ruby with warnings on.
#
# It parses and does not run: a gem's `lib` file, a demo's `db/seeds.rb` and a
# spec cannot run alone, as they need a database or a Rails boot. A parse runs
# no code, so the corpus can be the whole tracked tree. It is a spec, so the
# gems matrix runs it on every push.
#
# The contract has two tiers:
#
#   FAIL    the dead-binding family: «assigned but unused variable» and
#           «shadowing outer local variable». Both are about this repository's
#           own source, both are deterministic for a given parser, and neither
#           has a realistic false positive: an underscore prefix says
#           «deliberately dropped» in one character.
#   REPORT  every other parse warning, with its file and line, and not fatal. A
#           Ruby upgrade can start to warn about syntax this tree uses correctly
#           today; that must show, and it must not fail a build that nobody can
#           fix without a downgrade.
#
# It cannot catch:
#
#   * a runtime warning (a redefined method, a `Struct` member shadowing),
#     because that needs the file loaded. The exception is `already initialized
#     constant` between two spec files: a constant assigned outside a class or
#     module lands in Object, so two files in one suite that assign the same one
#     redefine each other. The last example reads that from the source. A method
#     that two files redefine has the same shape and is not read here.
#   * a variable that IS read, by code that never runs.
#   * anything outside a tracked `.rb` or `.rake` file: `.erb` templates, the
#     `.rb.tt` generator templates (not valid Ruby alone), untracked files.
#
# It reads the tracked tree and never skips.

require 'open3'
require 'stringio'

module ParseWarnings
  REPO_ROOT = File.expand_path('../..', __dir__)

  # The two shapes above, and only those, are fatal.
  FATAL = /warning: (?:assigned but unused variable|shadowing outer local variable)/

  module_function

  def tracked_files
    out, err, status = Open3.capture3('git', '-C', REPO_ROOT, 'ls-files', '-z', '*.rb', '*.rake')
    raise "git ls-files failed in #{REPO_ROOT}: #{err}" unless status.success?

    files = out.split("\0").reject(&:empty?)
    raise "git ls-files found no Ruby source at all under #{REPO_ROOT}" if files.empty?

    files
  end

  # [rel, warning text] for every parse warning of the file at `rel`. The text
  # names the file by its path in the repository.
  def warnings(rel)
    abs = File.join(REPO_ROOT, rel)
    return [] unless File.file?(abs)

    compile_warnings(abs, rel).each_line.map { |line| [rel, line.strip.sub("#{abs}:", '')] }
  end

  # Compiles in this process: `compile_file` emits the same warnings as
  # `ruby -c -w` and runs no code. It must be `compile_file`, not `compile`:
  # `compile` treats the top level as an eval scope and does not warn about an
  # unused variable there.
  def compile_warnings(abs, rel)
    captured = StringIO.new
    begin
      redirect_warnings(captured) { RubyVM::InstructionSequence.compile_file(abs) }
    rescue SyntaxError => e
      # A file that does not parse is a harder failure than a warning.
      captured.puts("#{rel}: warning: does not parse — #{e.message.lines.first.to_s.strip}")
    end
    captured.string
  end

  # Runs the block with warnings on and `$stderr` sent to `io`.
  def redirect_warnings(io)
    real    = $stderr
    verbose = $VERBOSE
    $stderr  = io
    $VERBOSE = true
    yield
  ensure
    $VERBOSE = verbose
    $stderr  = real
  end

  # [name, line] of each constant that this source assigns outside every class,
  # module and singleton class, that is, into Object.
  def object_constants(node, scoped: false, found: [])
    return found unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

    scoped ||= %i[CLASS MODULE SCLASS].include?(node.type)
    name = node.children.first
    found << [name, node.first_lineno] if node.type == :CDECL && name.is_a?(Symbol) && !scoped
    node.children.each { |child| object_constants(child, scoped:, found:) }
    found
  end

  # {[top-level directory, constant] => ["file:line", …]} over the spec files that RSpec loads.
  def spec_constants(files)
    declared = Hash.new { |hash, key| hash[key] = [] }
    files.grep(/_spec\.rb\z/).each do |rel|
      src = File.read(File.join(REPO_ROOT, rel))
      next unless src.include?('RSpec.describe')

      object_constants(RubyVM::AbstractSyntaxTree.parse(src)).each do |(name, line)|
        declared[[rel[%r{\A[^/]+}], name]] << "#{rel}:#{line}"
      end
    end
    declared
  end

  FILES = tracked_files.freeze
  WARNINGS = FILES.flat_map { |rel| warnings(rel) }.freeze
end

RSpec.describe 'no Ruby parse warning in tracked source (K-1718)' do
  # A derived corpus can go vacuous only by shrinking to nothing; the floor says so.
  it 'reads the whole tracked Ruby corpus, so a green run means something' do
    expect(ParseWarnings::FILES.length).to be > 500
  end

  it 'has no dead binding anywhere in tracked source' do
    fatal = ParseWarnings::WARNINGS.select { |(_, line)| line =~ ParseWarnings::FATAL }
    expect(fatal).to be_empty, lambda {
      "#{fatal.length} dead binding(s) across #{ParseWarnings::FILES.length} tracked Ruby file(s). " \
      'Read the value, or prefix the name with an underscore to say it is deliberately ' \
      "dropped — a deletion hides WHICH half of a destructuring went away.\n" +
        fatal.map { |(rel, line)| "  #{rel}:#{line}" }.join("\n")
    }
  end

  # The second tier: prints every other parse warning, so it is a number on
  # every run.
  it 'reports every other parse warning without failing on it' do
    rest = ParseWarnings::WARNINGS.reject { |(_, line)| line =~ ParseWarnings::FATAL }
    rest.each { |(rel, line)| RSpec.configuration.reporter.message("  NOTICE #{rel}: #{line}") }
    expect(rest.length).to be_a(Integer)
  end

  describe 'no constant assigned into Object by two spec files of one suite' do
    # Scope: the spec files that RSpec loads, so each one carries an
    # `RSpec.describe`. The demos run each `spec/*_spec.rb` as its own `ruby`
    # process, so the comparison is per top-level directory.
    it 'has no constant two spec files of one suite both assign into Object' do
      declared   = ParseWarnings.spec_constants(ParseWarnings::FILES)
      collisions = declared.select { |_, sites| sites.map { |s| s[/\A[^:]+/] }.uniq.length > 1 }

      expect(collisions).to be_empty, lambda {
        "#{collisions.length} constant(s) are assigned into Object by two spec files of one suite. " \
        "Whichever loads second wins, so editing one file silently changes the other's inputs. " \
        "Give it one home — a module in spec/support, required by both.\n" +
          collisions.map { |(gem, name), sites| "  #{gem}: #{name} — #{sites.join(', ')}" }.join("\n")
      }
    end
  end
end
