# frozen_string_literal: true

require 'kiosk'

# No demo may ship a cleartext AGENT-IdP stub, and no demo may override the
# engine's own agent-IdP at all. Assistants authenticate with the kiosk-pop
# JWTs that the engine mints, and `Kiosk::Server::IdentityResolution` falls back
# to the adapter that verifies them. So this reads the shipped tree:
#   - no demo, and not the e2e fixture host, ships a `stub_idp.rb` or a
#     `jwt_or_stub_idp.rb`;
#   - no demo initializer sets `c.agent_idp`: the engine's default is the whole
#     mechanism, and an override is how a second one gets in.
#
# That the default is the kiosk-pop verifier, and that it refuses a forged
# bearer in every environment, is asserted in kiosk-server's
# identity_resolution_spec.rb. This gem does not depend on kiosk-server.
#
# It never skips when the demos are absent.
module DemoAgentIdp
  REPO_ROOT    = File.expand_path('../..', __dir__)
  DEMO_ROOTS   = Dir.glob(File.join(REPO_ROOT, 'kiosk-demo-*')).select { |d| File.directory?(d) }.sort.freeze
  E2E_FIXTURES = File.join(REPO_ROOT, 'e2e', 'fixtures')

  module_function

  # [initializer, line] for each demo or e2e initializer that sets c.agent_idp.
  def overrides
    initializers = DEMO_ROOTS.map { |d| File.join(d, 'config/initializers/kiosk.rb') } +
                   [File.join(E2E_FIXTURES, 'initializer_kiosk.rb')]
    initializers.select { |f| File.exist?(f) }.filter_map do |f|
      line = File.readlines(f).find { |l| l =~ /^\s*c\.agent_idp\s*=/ }
      [f.sub("#{REPO_ROOT}/", ''), line.strip] if line
    end
  end
end

RSpec.describe "the demos' agent channel is the engine's own kiosk-pop verifier (T-104)" do
  it 'finds the demo tree where it expects it (this spec never skips)' do
    expect(DemoAgentIdp::DEMO_ROOTS.size).to be >= 7,
                                             'expected the operator demos beside kiosk-test-support, found ' \
                                             "#{DemoAgentIdp::DEMO_ROOTS.size} — this spec has drifted, fix the path"
    expect(Dir.exist?(DemoAgentIdp::E2E_FIXTURES)).to be(true), "expected e2e/fixtures at #{DemoAgentIdp::E2E_FIXTURES}"
  end

  it 'ships no self-asserted agent-bearer parser anywhere' do
    names  = %w[stub_idp.rb jwt_or_stub_idp.rb]
    strays = (DemoAgentIdp::DEMO_ROOTS.flat_map { |d| names.map { |n| File.join(d, 'app/services', n) } } +
              names.map { |n| File.join(DemoAgentIdp::E2E_FIXTURES, n) }).select { |p| File.exist?(p) }
    expect(strays).to be_empty,
                      "a cleartext agent-IdP stub is back: #{strays.join(', ')}. Assistants " \
                      'authenticate with the kiosk-pop JWT the engine minted (T-104); a ' \
                      'self-asserted `agent:u-…:a-…:r-…` parser lets anyone be any agent at any ' \
                      'role — that was K-539, and an env gate in front of it is not the fix.'
  end

  describe "the demos' c.agent_idp wiring" do
    it 'leaves c.agent_idp unset in every demo and in the e2e fixture host' do
      overrides = DemoAgentIdp.overrides
      expect(overrides).to be_empty,
                           "these set c.agent_idp: #{overrides.inspect}. The engine's " \
                           'DefaultAgentIdp verifies the tokens the engine mints, so a demo needs ' \
                           'no override — and an override is where a second, weaker verifier gets ' \
                           'in. Set it only to front an EXTERNAL agent-identity issuer.'
    end
  end
end
