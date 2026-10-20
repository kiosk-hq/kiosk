# frozen_string_literal: true

require 'kiosk'

# No demo may ship a cleartext USER-IdP stub, and every demo that authenticates
# a human does it with the real Devise adapter, in every environment. An
# environment gate on an arm that does not exist is not worth a test; that the
# arm cannot come back is. So this reads the shipped tree:
#   - no demo, and not the e2e fixture host, ships a `stub_user_idp.rb`;
#   - every `c.user_idp =` in a demo initializer names the Devise adapter, with
#     no `Rails.env.local?` arm in front of it.
#
# It never skips: the demos ship in this repository, so a missing tree means
# the spec has drifted.
module DemoUserIdp
  REPO_ROOT    = File.expand_path('../..', __dir__)
  DEMO_ROOTS   = Dir.glob(File.join(REPO_ROOT, 'kiosk-demo-*')).select { |d| File.directory?(d) }.sort.freeze
  E2E_FIXTURES = File.join(REPO_ROOT, 'e2e', 'fixtures')

  module_function

  # [demo, line] for each demo initializer that sets c.user_idp.
  def wirings
    DEMO_ROOTS.filter_map do |dir|
      initializer = File.join(dir, 'config/initializers/kiosk.rb')
      line = File.exist?(initializer) && File.readlines(initializer).find { |l| l =~ /^\s*c\.user_idp\s*=/ }
      [File.basename(dir), line.strip] if line
    end
  end
end

RSpec.describe "the demos' human channel is real Devise (T-066)" do
  it 'finds the demo tree where it expects it (this spec never skips)' do
    expect(DemoUserIdp::DEMO_ROOTS.size).to be >= 7,
                                            'expected the operator demos beside kiosk-test-support, found ' \
                                            "#{DemoUserIdp::DEMO_ROOTS.size} — this spec has drifted, fix the path"
    expect(Dir.exist?(DemoUserIdp::E2E_FIXTURES)).to be(true), "expected e2e/fixtures at #{DemoUserIdp::E2E_FIXTURES}"
  end

  it 'ships no stub user-IdP anywhere' do
    strays = (DemoUserIdp::DEMO_ROOTS.map { |d| File.join(d, 'app/services/stub_user_idp.rb') } +
              [File.join(DemoUserIdp::E2E_FIXTURES, 'stub_user_idp.rb')]).select { |p| File.exist?(p) }
    expect(strays).to be_empty,
                      "a cleartext user-IdP stub is back: #{strays.join(', ')}. Humans " \
                      'authenticate through kiosk-user-idp-devise (T-066); a self-asserted ' \
                      '`user:u-…` or `X-Staff-Session` parser lets anyone be anyone.'
  end

  describe "the demos' c.user_idp wiring" do
    it 'wires c.user_idp to the Devise adapter, unconditionally, wherever it is set' do
      wirings = DemoUserIdp.wirings
      # Every operator demo authenticates humans; only the KYC broker does not.
      expect(wirings.size).to be >= 7, "expected every operator demo to set c.user_idp, got #{wirings.inspect}"

      wirings.each do |demo, line|
        expect(line.squeeze(' ')).to eq('c.user_idp = Kiosk::UserIdentityProviders::Devise.new'),
                                     "#{demo} wires c.user_idp as `#{line}` — it must be the real Devise adapter " \
                                     'with no dev-only arm (T-066).'
      end
    end
  end
end
