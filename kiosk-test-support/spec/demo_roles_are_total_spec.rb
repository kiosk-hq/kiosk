# frozen_string_literal: true

require 'digest'
require 'kiosk'

# No shipped host may hand the binding ceremony a NIL role unless somebody has
# reasoned about it first.
#
# The hazard: `Kiosk::Server::AccountBinding.rebind` leaves an agent's
# `allowed_roles` unchanged when the ceremony carries no role, so that
# single-role and no-IdP providers keep working. On an origin that declares more
# than one role, an agent that already carries the privileged role, rebound to
# a human who holds none, keeps the privilege while `sub` becomes that human's.
#
# `requested_role` is nil only when the configured `user_idp` reports no role
# for a signed-in human. That is a property of each host's user model, not of
# the engine: `Kiosk::UserIdentityProviders::Devise#role_for` returns
# `user.kiosk_role` verbatim when the model defines it, nil included, and does
# not fall through to `Kiosk.configuration.roles.first` (a declaration order,
# not a privilege order). This spec makes that property stated and checked.
#
# Two invariants, one mechanical and one not:
#
#   1. Every demo (and the e2e fixture host) declares a NON-EMPTY `c.roles`.
#      The adapter falls back to it when a model defines no `#kiosk_role`, and
#      one line decides it.
#
#   2. Every `#kiosk_role` in the corpus is DECLARED here with a written reason
#      it cannot answer nil, and a fingerprint of its body. Whether a Ruby
#      method can return nil is not decidable by a pattern match, so the answer
#      is a human decision: editing the method changes the fingerprint and fails
#      the build until someone reads it again and declares it again.
#
# It never skips when the demos are absent.
module RolesTotal
  REPO_ROOT = File.expand_path('../..', __dir__)
  DEMOS     = Dir.glob(File.join(REPO_ROOT, 'kiosk-demo-*')).select { |d| File.directory?(d) }.sort.freeze
  E2E_INIT  = File.join(REPO_ROOT, 'e2e/fixtures/initializer_kiosk.rb')

  # Demos that configure no Kiosk engine, so no `c.roles` line is expected.
  # kiosk-demo-proveli is the KYC broker: a consumer of a Kiosk operator, not one.
  NO_ENGINE = %w[kiosk-demo-proveli].freeze

  # The declared `#kiosk_role` definitions: repo-relative path =>
  # [body fingerprint, the reason it cannot answer nil].
  #
  # To add or change one, run the suite, read the fingerprint from the failure
  # message, and write the reason beside it. The fingerprint hashes the method
  # BODY without comments and blank lines and with whitespace collapsed, so a
  # changed comment does not change it and a changed line of logic does.
  DECLARED = {
    'kiosk-demo-stylish/app/models/user.rb' => [
      'a936ee8b5ec51b49',
      'TOTAL by construction: `staff_role` is an enum validated on write to be ' \
      "'owner' or nil, and nil falls to the literal 'customer'."
    ]
  }.freeze

  module_function

  # The source of a `def kiosk_role` body in a file, or nil.
  def body(path)
    src = File.read(path)
    endless = src.match(/^\s*def kiosk_role\s*=\s*(.+)$/)
    return endless[1] if endless

    src.match(/^(\s*)def kiosk_role\b.*?\n(.*?)^\1end$/m)&.[](2)
  end

  # Comment-insensitive, whitespace-insensitive fingerprint of a method body.
  def fingerprint(body)
    normalized = body.lines
                     .map { |l| l.sub(/(\A|\s)#(?!\{).*$/, '') }
                     .reject { |l| l.strip.empty? }
                     .join(' ')
                     .gsub(/\s+/, ' ').strip
    Digest::SHA256.hexdigest(normalized)[0, 16]
  end

  # A problem note for each engine-configuring host that declares no role.
  def roleless_hosts
    initializers = DEMOS.reject { |d| NO_ENGINE.include?(File.basename(d)) }
                        .map { |d| File.join(d, 'config/initializers/kiosk.rb') } + [E2E_INIT]
    initializers.filter_map { |path| roles_problem(path) }
  end

  def roles_problem(path)
    rel = path.delete_prefix("#{REPO_ROOT}/")
    return "#{rel} (missing)" unless File.exist?(path)

    line = File.readlines(path).find { |l| l =~ /^\s*c\.roles\s*=/ }
    return "#{rel} (no c.roles line)" if line.nil?

    "#{rel} (#{line.strip})" if line[/%i\[\s*\]|=\s*\[\s*\]/]
  end

  # [repo-relative path, body] of every `#kiosk_role` in the corpus.
  def kiosk_roles
    (DEMOS.flat_map { |d| Dir.glob(File.join(d, 'app/**/*.rb')) } + Dir.glob(File.join(REPO_ROOT, 'e2e/fixtures/*.rb')))
      .sort
      .filter_map { |path| body(path)&.then { |found| [path.delete_prefix("#{REPO_ROOT}/"), found] } }
  end

  def drifted(found)
    found.filter_map do |rel, body|
      want = DECLARED.fetch(rel).first
      got  = fingerprint(body)
      "#{rel}: declared #{want}, now #{got}" unless want == got
    end
  end
end

RSpec.describe 'no shipped host hands the binding ceremony a nil role (K-1124)' do
  it 'finds the demo tree where it expects it (this spec never skips)' do
    expect(RolesTotal::DEMOS.size).to be >= 7,
                                      'expected the operator demos beside kiosk-test-support, ' \
                                      "found #{RolesTotal::DEMOS.size} — this spec has drifted"
    expect(File.exist?(RolesTotal::E2E_INIT)).to be(true), "expected #{RolesTotal::E2E_INIT}"
  end

  # Invariant 1: the adapter's default arm is never the nil one.
  it 'declares a non-empty c.roles in every engine-configuring host' do
    empty = RolesTotal.roleless_hosts
    expect(empty).to be_empty,
                     "these hosts declare no role: #{empty.join(', ')}. A model without " \
                     '`#kiosk_role` then resolves to no role at all, and a role-less ' \
                     'ceremony binds at `registration_role` — so a human the IdP cannot ' \
                     'answer for gets an assistant that cannot act for them (K-1124, K-1791).'
  end

  # Invariant 2: every #kiosk_role is declared, with a reason, at a pinned body.
  describe 'every #kiosk_role is declared total (K-1124)' do
    it 'declares every #kiosk_role in the corpus, at the body that was reasoned about' do
      found = RolesTotal.kiosk_roles
      undeclared = found.map(&:first).reject { |rel| RolesTotal::DECLARED.key?(rel) }
      expect(undeclared).to be_empty,
                            "a new #kiosk_role appeared and nobody has said whether it can answer nil: #{undeclared.join(', ')}. " \
                            'Declare it in ROLES_TOTAL_DECLARED with a reason and the ' \
                            'fingerprint the drift check names, or make the method total.'

      gone = RolesTotal::DECLARED.keys - found.map(&:first)
      expect(gone).to be_empty,
                      "declared but no longer present: #{gone.join(', ')} — delete the entry, an " \
                      'exception for a method that does not exist is a comfortable lie.'

      drifted = RolesTotal.drifted(found)
      expect(drifted).to be_empty,
                         "a declared #kiosk_role changed: #{drifted.join('; ')}. Re-read the method, " \
                         'decide again whether it can answer nil, then update the fingerprint AND ' \
                         'the reason beside it.'
    end
  end
end
