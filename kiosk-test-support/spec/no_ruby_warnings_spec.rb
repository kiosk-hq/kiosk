# frozen_string_literal: true

# K-1718: NOTHING IN THIS REPOSITORY EVER RAN RUBY IN WARNING MODE, so a dead
# binding could sit in shipped code indefinitely and the interpreter would say
# so on every parse to nobody.
#
# WHAT WENT WRONG, and it is the reason this is a guard and not four edits.
# `e2e/fixtures/register_pow_flow.rb` destructured a two-element return into
# `reg_key, reg` and read only `reg`, so a keypair was bound and never used —
# in a fixture whose whole subject is that the keypair is what registers. Ruby
# names that defect precisely, for free, at parse time. The census that found
# it — `ruby -c -w` over every tracked `.rb` — answered eleven warnings across
# five files, every one of them «assigned but unused variable», and a search
# for a warning-mode invocation over `bin/`, the workflows, the Rakefiles and
# the spec helpers answered ONE line, which was a sentence in a header rather
# than a command anything ran.
#
# WHY THIS AND NOT `audit/check-script-warnings.rb`, which is the workspace's
# other Ruby-warning gate and was the obvious place to widen. That gate EXECUTES
# its corpus: it runs each guard script in a subprocess under `-w` and reads the
# stderr of a real run. A gem's `lib` file, a demo's `db/seeds.rb` and a spec are
# not runnable that way — half of them would need a database and the rest would
# need a Rails boot — so widening its corpus is not an option that exists. The
# instrument for source is the OTHER verb of the same flag: PARSE it. Nothing is
# executed here, so there is no library noise to filter and no service to stand
# up, and the corpus can be the whole tracked tree.
#
# WHY A SPEC AND NOT A `bin/check-*`. It has to reach CI to be worth anything,
# and `kiosk-test-support` is in the gems matrix, so a spec here gates every push
# without a workflow of its own — the same reason `kiosk_names_check_spec.rb`,
# `no_dated_literals_spec.rb` and `skill_pin_spec.rb` live beside it.
#
# THE CONTRACT IS TWO-TIER, deliberately, and it is NOT the same split
# `check-script-warnings.rb` makes:
#
#   FAIL    the DEAD-BINDING family — «assigned but unused variable» and
#           «shadowing outer local variable». Both are statements about THIS
#           repository's own source, both are deterministic under a given
#           parser, and neither has a realistic false positive: a binding
#           nobody reads is either dead or misspelt, and an underscore prefix
#           says «deliberately dropped» in one character.
#   REPORT  every other parse warning, printed with its file and line and NOT
#           fatal. A Ruby upgrade may start warning about a syntax this tree
#           uses correctly today; that must surface, and it must not redden a
#           build nobody can fix without upgrading back. K-1097's trade,
#           applied to the half of the output that is not ours to promise.
#
# WHAT IT CANNOT CATCH, stated plainly because a parse is not an execution:
#
#   * every RUNTIME warning — a redefined method, an already-initialised
#     constant, a `Struct` member shadowing. Those need the file loaded, which
#     is `audit/check-script-warnings.rb`'s job over the corpus that CAN be run.
#   * a variable that IS read, by code that never executes.
#   * anything outside a tracked `.rb` or `.rake` file: `.erb` templates, the
#     `.rb.tt` generator templates (which are not valid Ruby on their own), and
#     any file `git ls-files` does not carry.
#
# It reads the TRACKED tree and does NOT skip when that tree is not where it
# expects (K-502): a guard that goes quiet when its inputs move proves nothing.

require "open3"
require "stringio"

WARNINGS_REPO_ROOT = File.expand_path("../..", __dir__)

# The two shapes above, and only those, are fatal.
FATAL_WARNING = /warning: (?:assigned but unused variable|shadowing outer local variable)/.freeze

RSpec.describe "no Ruby parse warning in tracked source (K-1718)" do
  # Compiled IN THIS PROCESS rather than by one `ruby -c -w` subprocess per
  # file: `compile_file` emits the identical warnings and never executes the
  # source, so the whole tree costs a second instead of the minute eight hundred
  # subprocesses would.
  #
  # IT MUST BE `compile_file` AND NOT `compile`, and this was MEASURED by the
  # plant rather than reasoned about — the first writing used
  # `compile(File.read(abs), rel)` and was VACUOUS: on the very defect this
  # guard is named for it reported nothing, because that entry point treats the
  # script's top level as an eval scope where a local may still be read from
  # outside, so it withholds the unused-variable warning there. `compile_file`
  # on the identical file reports it, and so does `ruby -c -w`. A guard that had
  # only been run green would have shipped blind.
  def self.parse_warnings
    out, err, status = Open3.capture3("git", "-C", WARNINGS_REPO_ROOT, "ls-files", "-z", "*.rb", "*.rake")
    raise "git ls-files failed in #{WARNINGS_REPO_ROOT}: #{err}" unless status.success?

    files = out.split("\0").reject(&:empty?)
    raise "git ls-files found no Ruby source at all under #{WARNINGS_REPO_ROOT}" if files.empty?

    warnings = []
    verbose  = $VERBOSE
    files.each do |rel|
      abs = File.join(WARNINGS_REPO_ROOT, rel)
      next unless File.file?(abs)

      captured = StringIO.new
      real     = $stderr
      begin
        $stderr  = captured
        $VERBOSE = true
        RubyVM::InstructionSequence.compile_file(abs)
      rescue SyntaxError => e
        # A file this repository cannot parse is a harder failure than a
        # warning, and it is reported as one rather than swallowed.
        captured.puts("#{rel}: warning: does not parse — #{e.message.lines.first.to_s.strip}")
      ensure
        $VERBOSE = verbose
        $stderr  = real
      end
      # `compile_file` names the file by the path it was given, which is
      # absolute; the report says where the file is IN THE REPOSITORY.
      captured.string.each_line { |l| warnings << [rel, l.strip.sub("#{abs}:", "")] }
    end
    [files, warnings]
  end

  FILES, WARNINGS = parse_warnings

  # The corpus is derived, so the only way it can go vacuous is by shrinking to
  # nothing — which would exit green forever. A floor says so instead.
  it "reads the whole tracked Ruby corpus, so a green run means something" do
    expect(FILES.length).to be > 500
  end

  it "has no dead binding anywhere in tracked source" do
    fatal = WARNINGS.select { |(_, line)| line =~ FATAL_WARNING }
    expect(fatal).to be_empty, lambda {
      "#{fatal.length} dead binding(s) across #{FILES.length} tracked Ruby file(s). " \
      "Read the value, or prefix the name with an underscore to say it is deliberately " \
      "dropped — a deletion hides WHICH half of a destructuring went away.\n" +
        fatal.map { |(rel, line)| "  #{rel}:#{line}" }.join("\n")
    }
  end

  # Not an assertion: the other tier. A parse warning this guard does not gate
  # is printed so it is a number on every run rather than a belief, which is
  # the half `audit/check-script-warnings.rb` calls NOTICE.
  it "reports every other parse warning without failing on it" do
    rest = WARNINGS.reject { |(_, line)| line =~ FATAL_WARNING }
    rest.each { |(rel, line)| RSpec.configuration.reporter.message("  NOTICE #{rel}: #{line}") }
    expect(rest.length).to be_a(Integer)
  end
end
