# frozen_string_literal: true

require "digest"
require "kiosk"

# K-1124 regression: NO shipped host may hand the binding ceremony a NIL role
# without somebody having reasoned about it first.
#
# WHAT THE HAZARD IS. `Kiosk::Server::AccountBinding.rebind` leaves an agent's
# `allowed_roles` UNTOUCHED when the ceremony carries no role — ADR-0011's
# explicit no-regression clause, so that single-role and no-IdP providers keep
# working. On an origin declaring MORE than one role that clause says something
# sharper: an agent already carrying the privileged role, rebound to a
# different human who holds none, KEEPS the privilege while `sub` becomes that
# human's.
#
# WHY IT IS NOT LIVE, AND WHY THAT IS NOT ENOUGH. Post-K-072 a claim row takes
# its role from the approving human and a link row from its minter, so
# `requested_role` is nil only when the configured `user_idp` reported no role
# for a signed-in human. In this fleet none ever does. But that is a property
# of each HOST's user model, not of the engine and not of the shipped Devise
# adapter: `Kiosk::UserIdentityProviders::Devise#role_for` returns
# `user.kiosk_role` VERBATIM when the model defines it — nil included, with no
# fall-through to `Kiosk.configuration.roles.first` (its own suite pins that,
# and the reason it must not fall through is that `roles.first` is a
# DECLARATION order, not a privilege order).
#
# So the safety of a live security branch rests on an unstated property of
# seven application models. That is the shape K-072's expired mitigation had —
# «safe because every demo declares one role», true when written and false two
# months later with nothing to notice. This spec is the noticing.
#
# TWO INVARIANTS, and the split is deliberate — one is mechanical, one is not:
#
#   1. Every demo (and the e2e fixture host) declares a NON-EMPTY `c.roles`.
#      That is the arm the adapter falls back to when a model defines no
#      `#kiosk_role` at all, and it is decidable by reading one line.
#
#   2. Every `#kiosk_role` in the corpus is DECLARED here with a written reason
#      it cannot answer nil, together with a fingerprint of its body. Whether a
#      Ruby method can return nil is not decidable by grep — stylish's returns
#      a bare `staff_role` column on one branch and is total only because an
#      `include?` guard stands in front of it, which no pattern match can see —
#      so this does not pretend to decide it. It makes the answer a HUMAN
#      DECISION with an expiry: editing the method changes the fingerprint and
#      fails the build until someone re-reads it and re-declares.
#
# It does NOT skip when the demos are absent (K-502): a guard that goes quiet
# when its subject moves is worse than no guard.
ROLES_TOTAL_REPO_ROOT = File.expand_path("../..", __dir__)
ROLES_TOTAL_DEMOS     = Dir.glob(File.join(ROLES_TOTAL_REPO_ROOT, "kiosk-demo-*"))
                           .select { |d| File.directory?(d) }.sort
ROLES_TOTAL_E2E_INIT   = File.join(ROLES_TOTAL_REPO_ROOT, "e2e/fixtures/initializer_kiosk.rb")

# Demos that configure no Kiosk engine at all, so no `c.roles` line is expected.
# kiosk-demo-prove is the KYC broker: it is a CONSUMER of a Kiosk operator, not
# one itself, and does not load kiosk-server.
ROLES_TOTAL_NO_ENGINE = %w[kiosk-demo-prove].freeze

# The declared `#kiosk_role` definitions. Key = repo-relative path; value =
# [body fingerprint, the reason it cannot answer nil].
#
# To add or change one: run the suite and read the fingerprint out of the
# failure message, then write the reason beside it. The fingerprint is a hash of the method BODY with comments
# and blank lines removed and whitespace collapsed, so re-wording the comment
# above a method does not flap this, and changing one line of its logic does.
ROLES_TOTAL_DECLARED = {
  "kiosk-demo-stylish/app/models/user.rb" => [
    "40d07e575f70d81a",
    "TOTAL by construction (K-712h). Non-staff short-circuit to the literal " \
    "'customer'; staff return `staff_role` only when it is a member of " \
    "`Kiosk.configuration.roles` mapped to strings, and nil is not a member of " \
    "that set — so the nil column value that a bare varchar with no CHECK " \
    "constraint permits falls to the literal 'customer' fallback. The " \
    "least-privileged declared role is also the correct direction for an " \
    "authorization input.",
  ],
}.freeze

# Extract the source of a `def kiosk_role` body from a file, or nil.
def roles_total_body(path)
  src = File.read(path)
  m = src.match(/^(\s*)def kiosk_role\b.*?\n(.*?)^\1end$/m)
  m && m[2]
end

# Comment-insensitive, whitespace-insensitive fingerprint of a method body.
def roles_total_fingerprint(body)
  normalized = body.lines
                   .map { |l| l.sub(/(\A|\s)#(?!\{).*$/, "") }
                   .reject { |l| l.strip.empty? }
                   .join(" ")
                   .gsub(/\s+/, " ").strip
  Digest::SHA256.hexdigest(normalized)[0, 16]
end

RSpec.describe "no shipped host hands the binding ceremony a nil role (K-1124)" do
  it "finds the demo tree where it expects it (this spec never skips)" do
    expect(ROLES_TOTAL_DEMOS.size).to be >= 7,
                                      "expected the operator demos beside kiosk-test-support, " \
                                      "found #{ROLES_TOTAL_DEMOS.size} — this spec has drifted"
    expect(File.exist?(ROLES_TOTAL_E2E_INIT)).to be(true),
                                                 "expected #{ROLES_TOTAL_E2E_INIT}"
  end

  # Invariant 1 — the adapter's default arm is never the nil one.
  it "declares a non-empty c.roles in every engine-configuring host" do
    initializers =
      ROLES_TOTAL_DEMOS
      .reject { |d| ROLES_TOTAL_NO_ENGINE.include?(File.basename(d)) }
      .map { |d| File.join(d, "config/initializers/kiosk.rb") } + [ROLES_TOTAL_E2E_INIT]

    empty = initializers.filter_map do |path|
      rel  = path.delete_prefix("#{ROLES_TOTAL_REPO_ROOT}/")
      next "#{rel} (missing)" unless File.exist?(path)

      line = File.readlines(path).find { |l| l =~ /^\s*c\.roles\s*=/ }
      next "#{rel} (no c.roles line)" if line.nil?
      next unless line[/%i\[\s*\]|=\s*\[\s*\]/]

      "#{rel} (#{line.strip})"
    end

    expect(empty).to be_empty,
                     "these hosts declare no role: #{empty.join(", ")}. A model without " \
                     "`#kiosk_role` then resolves to no role at all, and a role-less " \
                     "ceremony is what leaves a rebind's allowed_roles untouched (K-1124)."
  end

  # Invariant 2 — every #kiosk_role is declared, with a reason, at a pinned body.
  it "declares every #kiosk_role in the corpus, at the body that was reasoned about" do
    found = (ROLES_TOTAL_DEMOS.flat_map { |d| Dir.glob(File.join(d, "app/**/*.rb")) } +
             Dir.glob(File.join(ROLES_TOTAL_REPO_ROOT, "e2e/fixtures/*.rb")))
           .sort
           .filter_map do |path|
             body = roles_total_body(path)
             body && [path.delete_prefix("#{ROLES_TOTAL_REPO_ROOT}/"), body]
           end

    undeclared = found.reject { |rel, _| ROLES_TOTAL_DECLARED.key?(rel) }
    expect(undeclared.map(&:first)).to be_empty,
                                       "a new #kiosk_role appeared and nobody has said whether " \
                                       "it can answer nil: #{undeclared.map(&:first).join(", ")}. " \
                                       "Declare it in ROLES_TOTAL_DECLARED with a reason and the " \
                                       "fingerprint the drift check names, or make the method total."

    gone = ROLES_TOTAL_DECLARED.keys - found.map(&:first)
    expect(gone).to be_empty,
                    "declared but no longer present: #{gone.join(", ")} — delete the entry, an " \
                    "exception for a method that does not exist is a comfortable lie."

    drifted = found.filter_map do |rel, body|
      want = ROLES_TOTAL_DECLARED.fetch(rel).first
      got  = roles_total_fingerprint(body)
      "#{rel}: declared #{want}, now #{got}" unless want == got
    end
    expect(drifted).to be_empty,
                       "a declared #kiosk_role changed: #{drifted.join("; ")}. Re-read the method, " \
                       "decide again whether it can answer nil, then update the fingerprint AND " \
                       "the reason beside it."
  end
end
