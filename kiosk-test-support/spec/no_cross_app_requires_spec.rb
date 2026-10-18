# frozen_string_literal: true

# No demo may `require` its way into another demo's tree. Each demo has its own
# Gemfile, initializers and autoloader, so a file that crosses that boundary is
# loaded under a configuration it was not written for. `bin/check-demo-copies`
# cannot see this: it compares copies at matching relative paths.
#
# There are three kinds of reach, and only one is forbidden:
#
#   * an in-process `require` / `require_relative`: FORBIDDEN, because it puts
#     foreign source in this process.
#   * a data-file path read: allowed. A PEM is bytes, not code.
#   * an out-of-process app boot: allowed. A harness names another app's
#     directory to spawn a second server there.
#
# So it reads require statements and nothing else, and the examples on
# synthetic input hold it to that. It reads the tracked tree (`git ls-files`),
# so the vendored `.gems/` bundle is out of scope, and it never skips.

require 'open3'

module CrossAppRequires
  REPO_ROOT = File.expand_path('../..', __dir__)

  # `require "x"` / `require_relative 'x'` / `require(File.expand_path("…"))`:
  # the leading token and the first quoted string on the line. A `require`
  # whose argument is computed at run time is not matched.
  REQUIRE = /^[ \t]*(require_relative|require)\b[ \t(]*(?:File\.expand_path\([ \t]*)?["']([^"']+)["']/

  module_function

  # [git succeeded?, the tracked .rb/.rake files of the demos and e2e]
  def tracked_files
    tracked, status = Open3.capture2('git', '-C', REPO_ROOT, 'ls-files', 'kiosk-demo-*', 'e2e')
    [status.success?, tracked.lines(chomp: true).select { |f| f.end_with?('.rb', '.rake') }.sort.freeze]
  end

  # Which `kiosk-demo-*` app owns a repo-relative path, if any.
  def owner(rel_path) = rel_path[/\Akiosk-demo-[a-z0-9_]+/]

  # [owner demo, repo-relative path] that a require statement lands in, or nil
  # when it names a gem or points outside the demos.
  def require_target(rel_path, kind, arg)
    abs = required_path(rel_path, kind, arg)
    return nil if abs.nil?

    rel = abs.delete_prefix("#{REPO_ROOT}/")
    owner(rel)&.then { |demo| [demo, rel] }
  end

  # The absolute path of a `require_relative`, or of a `require` that names a
  # demo (read from the first segment that names one).
  def required_path(rel_path, kind, arg)
    if kind == 'require_relative'
      File.expand_path(arg, File.join(REPO_ROOT, File.dirname(rel_path)))
    elsif arg.include?('kiosk-demo-')
      File.expand_path(arg[/kiosk-demo-.*/], REPO_ROOT)
    end
  end

  def violations(files)
    files.flat_map do |rel|
      File.read(File.join(REPO_ROOT, rel)).each_line.with_index(1).filter_map do |line, lineno|
        violation(rel, line, lineno)
      end
    end
  end

  # The report line for a require that reaches into another app, or nil.
  def violation(rel, line, lineno)
    match = line.match(REQUIRE)
    into, into_rel = match && require_target(rel, match[1], match[2])
    from = owner(rel)
    return nil if into.nil? || into == from

    "#{rel}:#{lineno} requires #{into_rel} (#{from || 'e2e'} → #{into})"
  end
end

RSpec.describe "no demo requires another demo's source into its process (K-683)" do
  let(:tracked) { CrossAppRequires.tracked_files }

  it 'reads the tracked tree (this spec never skips)' do
    git_ok, files = tracked
    expect(git_ok).to be(true), "git ls-files failed in #{CrossAppRequires::REPO_ROOT}"
    expect(files.size).to be >= 200,
                          "found only #{files.size} tracked .rb/.rake files under the demos " \
                          'and e2e — this guard has drifted, fix the path'
    expect(files.count { |f| f.start_with?('e2e/') }).to be >= 5
  end

  it 'finds no cross-app require anywhere in the demos or the e2e harness' do
    expect(CrossAppRequires.violations(tracked.last)).to be_empty,
                                                         "a file loaded another standalone Rails app's source into its " \
                                                         'own process (K-681). Boot the other app out of process, or ' \
                                                         'copy the file and declare the copy in bin/check-demo-copies'
  end
end

# Written against strings rather than the tree: on a clean tree only examples
# like these show which of the three kinds the rule catches. A stubbed
# `File.read` is the whole fixture; the path arithmetic runs against the real
# repository root.
RSpec.describe 'the cross-app require shapes it forbids, and the shapes it does not' do
  def source(rel, body)
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(File.join(CrossAppRequires::REPO_ROOT, rel)).and_return(body)
    rel
  end

  it 'FORBIDS an in-process require_relative into another demo' do
    rel = source('kiosk-demo-skooti/script/rental_flow.rb',
                 %(require_relative "../../kiosk-demo-prove/app/services/prove_key"\n))
    expect(CrossAppRequires.violations([rel]).first).to include('kiosk-demo-skooti', 'kiosk-demo-prove')
  end

  it 'ALLOWS a data-file path read — a PEM is bytes, not code' do
    rel = source('kiosk-demo-skooti/script/rental_flow.rb', %(DEV_KEY_PATH = "../kiosk-demo-prove/config/dev_key.pem"\n))
    expect(CrossAppRequires.violations([rel])).to be_empty
  end

  it "ALLOWS naming another app's directory in order to BOOT it (K-663)" do
    rel = source('kiosk-demo-skooti/script/rental_flow.rb',
                 %(BROKER_APP = File.expand_path("../../kiosk-demo-prove", __dir__)\n) +
                 %(spawn({}, "bin/rails s", chdir: BROKER_APP)\n))
    expect(CrossAppRequires.violations([rel])).to be_empty
  end

  it "FORBIDS the e2e harness reaching into a demo's app/ or config/" do
    rel = source('e2e/fixtures/bind_assistants.rb', %(require_relative "../../kiosk-demo-stylish/app/models/user"\n))
    expect(CrossAppRequires.violations([rel]).first).to include('e2e → kiosk-demo-stylish')
  end
end
