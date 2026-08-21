# frozen_string_literal: true

# K-683: no demo may `require` its way into another demo's tree.
#
# WHAT THIS CATCHES, AND WHY NOTHING ELSE DID. K-681 was skooti's
# `prove_test_issuer.rb` loading `kiosk-demo-prove/lib/prove_key.rb` — one
# standalone Rails app pulling another standalone Rails app's source into its
# own process. Each demo has its own Gemfile, its own initializers and its own
# autoloader, so a file that crosses that boundary is loaded under a
# configuration it was never written for; it stayed green in every local gate
# and was found only by a full runner build of `demo:rideflow`, days after
# merge. None of the four `bin/check-*` scripts can see it by construction:
# check-demo-copies compares copies at MATCHING relative paths, so a file
# reaching ACROSS apps is invisible to it; check-ci-tasks reads task wiring;
# check-gem-packaging reads built gems; check-solver-pin probes the live site.
#
# THREE KINDS OF REACH, AND ONLY ONE IS FORBIDDEN. The distinction is the whole
# design of this guard, because the other two are accepted shapes that a naive
# "does this file mention another demo" grep would red-flag:
#
#   * an in-process `require` / `require_relative` — FORBIDDEN. This is the one
#     that puts foreign source in this process.
#   * a DATA-FILE path read — allowed. skooti's `prove_test_issuer.rb` names
#     the broker's dev PEM; a PEM is bytes, not code.
#   * an OUT-OF-PROCESS app boot — allowed. `prove_broker_boot.rb`'s
#     `BROKER_APP` names the broker's directory in order to SPAWN a second
#     server there, which is K-663's accepted harness shape.
#
# So the guard reads require statements and nothing else, and the synthetic
# examples at the bottom pin that it stays that way.
#
# THE ONE SANCTIONED CROSSING is `e2e/fixtures/*` requiring a demo's
# `script/*` — the harness deliberately runs a shipped demo driver rather than
# maintaining a ninth copy of the binding ceremony. Those drivers are bare
# `ruby` processes with no Rails in them, which is exactly why it is safe; a
# reach into a demo's `app/`, `config/` or `lib/` is not, and fails here.
#
# It reads the TRACKED tree (`git ls-files`), so a vendored `.gems/` bundle —
# which is full of legitimate `require_relative "../../lib/foo"` — is out of
# scope by construction rather than by an exclusion list.
#
# It does NOT skip when the tree is not where it expects (K-502): a guard that
# goes quiet when its inputs move proves nothing after the next move.

require "open3"

XAPP_REPO_ROOT = File.expand_path("../..", __dir__)

# `require "x"` / `require_relative 'x'` / `require(File.expand_path("…"))` —
# the leading token plus the first quoted string on the line. A `require` whose
# argument is fully computed at runtime is not matched and cannot be; that is a
# known limit, and it is why this is a guard against the SHAPE K-681 took
# (a literal path) rather than a proof of absence.
XAPP_REQUIRE = /^[ \t]*(require_relative|require)\b[ \t(]*(?:File\.expand_path\([ \t]*)?["']([^"']+)["']/

# Which `kiosk-demo-*` app owns a repo-relative path, if any.
def xapp_owner(rel_path)
  rel_path[%r{\Akiosk-demo-[a-z0-9_]+}]
end

# The demo tree a require statement lands in, or nil when it stays inside the
# repo's own file, names a gem, or points outside the demos altogether.
def xapp_require_target(rel_path, kind, arg)
  abs =
    if kind == "require_relative"
      File.expand_path(arg, File.join(XAPP_REPO_ROOT, File.dirname(rel_path)))
    elsif arg.include?("kiosk-demo-")
      # An absolute-ish `require` that spells a demo out: normalise from the
      # first segment that names one, whatever precedes it.
      File.expand_path(arg[/kiosk-demo-.*/], XAPP_REPO_ROOT)
    end
  return nil if abs.nil?

  rel = abs.delete_prefix("#{XAPP_REPO_ROOT}/")
  owner = xapp_owner(rel)
  owner.nil? ? nil : [owner, rel]
end

def xapp_violations(files)
  files.flat_map do |rel|
    src = File.read(File.join(XAPP_REPO_ROOT, rel))
    from = xapp_owner(rel)
    src.each_line.with_index(1).filter_map do |line, lineno|
      m = line.match(XAPP_REQUIRE)
      next if m.nil?

      target = xapp_require_target(rel, m[1], m[2])
      next if target.nil?

      into, into_rel = target
      next if into == from                       # inside its own app: fine
      # The one sanctioned crossing: the e2e harness runs a demo's Rails-free
      # driver rather than keeping a ninth copy of it.
      next if from.nil? && rel.start_with?("e2e/") && into_rel.start_with?("#{into}/script/")

      "#{rel}:#{lineno} requires #{into_rel} (#{from || "e2e"} → #{into})"
    end
  end
end

RSpec.describe "no demo requires another demo's source into its process (K-683)" do
  tracked, status = Open3.capture2(
    "git", "-C", XAPP_REPO_ROOT, "ls-files", "kiosk-demo-*", "e2e"
  )
  XAPP_GIT_OK = status.success?
  XAPP_FILES  = tracked.lines(chomp: true).select { |f| f.end_with?(".rb", ".rake") }.sort.freeze

  it "reads the tracked tree (this spec never skips)" do
    expect(XAPP_GIT_OK).to be(true), "git ls-files failed in #{XAPP_REPO_ROOT}"
    expect(XAPP_FILES.size).to be >= 200,
                               "found only #{XAPP_FILES.size} tracked .rb/.rake files under the demos " \
                               "and e2e — this guard has drifted, fix the path"
    expect(XAPP_FILES.count { |f| f.start_with?("e2e/") }).to be >= 5
  end

  it "finds no cross-app require anywhere in the demos or the e2e harness" do
    expect(xapp_violations(XAPP_FILES)).to be_empty,
                                           "a file loaded another standalone Rails app's source into its " \
                                           "own process (K-681). Boot the other app out of process, or " \
                                           "copy the file and declare the copy in bin/check-demo-copies"
  end

  # ── the three-kinds distinction, pinned on synthetic inputs ────────────────
  #
  # Written against strings rather than the tree, because what has to hold is
  # the RULE, and the tree is (correctly) free of violations — an example that
  # only ever sees a clean tree cannot show which of the three kinds it would
  # have caught.
  describe "the shape it forbids, and the two it does not" do
    # `xapp_violations` reads each file through File.read, so a stubbed read is
    # the whole probe — no temp tree, and the resolver still does the real
    # path arithmetic against the real repo root.
    def source(rel, body)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(File.join(XAPP_REPO_ROOT, rel)).and_return(body)
      rel
    end

    it "FORBIDS an in-process require_relative into another demo" do
      rel = source("kiosk-demo-skooti/lib/prove_test_issuer.rb",
                   %(require_relative "../../kiosk-demo-prove/app/services/prove_key"\n))
      expect(xapp_violations([rel]).first).to include("kiosk-demo-skooti", "kiosk-demo-prove")
    end

    it "ALLOWS a data-file path read — a PEM is bytes, not code" do
      rel = source("kiosk-demo-skooti/lib/prove_test_issuer.rb",
                   %(DEV_KEY_PATH = "../kiosk-demo-prove/config/dev_key.pem"\n))
      expect(xapp_violations([rel])).to be_empty
    end

    it "ALLOWS naming another app's directory in order to BOOT it (K-663)" do
      rel = source("kiosk-demo-skooti/script/prove_broker_boot.rb",
                   %(BROKER_APP = File.expand_path("../../kiosk-demo-prove", __dir__)\n) +
                   %(spawn({}, "bin/rails s", chdir: BROKER_APP)\n))
      expect(xapp_violations([rel])).to be_empty
    end

    it "ALLOWS the e2e harness to run a demo's Rails-free driver" do
      rel = source("e2e/fixtures/bind_assistants.rb",
                   %(require_relative "../../kiosk-demo-stylish/script/bound_assistant"\n))
      expect(xapp_violations([rel])).to be_empty
    end

    it "FORBIDS the e2e harness reaching into a demo's app/ or config/" do
      rel = source("e2e/fixtures/bind_assistants.rb",
                   %(require_relative "../../kiosk-demo-stylish/app/models/user"\n))
      expect(xapp_violations([rel]).first).to include("e2e → kiosk-demo-stylish")
    end
  end
end
