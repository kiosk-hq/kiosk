# frozen_string_literal: true

RSpec.shared_context 'with a Devise adapter' do
  subject(:adapter) { described_class.new }

  let(:user_id) { '11111111-1111-1111-1111-111111111111' }

  before { Kiosk.configure { |c| c.roles = %i[customer master] } }
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify when current_user is present' do
  include_context 'with a Devise adapter'

  let(:user)    { FakeUser.new(id: user_id) }
  let(:request) { FakeRequest.new(current_user: user) }

  it "returns a Kiosk::Identity with the user's id" do
    identity = adapter.verify(request)

    expect(identity).to be_a(Kiosk::Identity)
    expect(identity.user_id).to eq(user_id)
  end

  it 'marks the identity as a human actor (no agent_id)' do
    identity = adapter.verify(request)

    expect(identity.actor).to    eq('human')
    expect(identity.agent_id).to be_nil
  end

  it 'passes through an empty claims hash (Devise has no extra claims)' do
    expect(adapter.verify(request).claims).to eq({})
  end
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify when current_user is nil' do
  include_context 'with a Devise adapter'

  let(:request) { FakeRequest.new(current_user: nil) }

  it 'returns nil (covers unauthenticated, locked, and unconfirmed uniformly)' do
    # Devise's `active_for_authentication?` already gates `current_user`,
    # so a locked or unconfirmed user yields `current_user == nil` —
    # one signal, three failure modes, no extra branching in the adapter.
    expect(adapter.verify(request)).to be_nil
  end
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify role resolution' do
  include_context 'with a Devise adapter'

  it 'uses #kiosk_role when the user model defines it' do
    user    = FakeUser.new(id: user_id, kiosk_role: :master)
    request = FakeRequest.new(current_user: user)

    expect(adapter.verify(request).role).to eq('master')
  end

  it 'falls back to the first symbol in Kiosk.configuration.roles' do
    user    = FakeUser.new(id: user_id)
    request = FakeRequest.new(current_user: user)

    expect(adapter.verify(request).role).to eq('customer')
  end
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify role resolution with no roles configured' do
  include_context 'with a Devise adapter'

  it 'raises ConfigurationError when roles is empty AND #kiosk_role is undefined' do
    Kiosk.configure { |c| c.roles = [] }
    user    = FakeUser.new(id: user_id)
    request = FakeRequest.new(current_user: user)

    expect { adapter.verify(request) }.to raise_error(
      described_class::ConfigurationError,
      /Cannot resolve a role.*kiosk_role/m
    )
  end

  it 'does NOT raise when roles is empty but #kiosk_role IS defined' do
    Kiosk.configure { |c| c.roles = [] }
    user    = FakeUser.new(id: user_id, kiosk_role: :customer)
    request = FakeRequest.new(current_user: user)

    expect(adapter.verify(request).role).to eq('customer')
  end
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify role resolution with a nil #kiosk_role' do
  include_context 'with a Devise adapter'

  # A model that defines `#kiosk_role` owns the answer. A nil does not fall
  # through to `roles.first`: that is a declaration order, not a privilege
  # order, and could hand out the privileged role. So a `#kiosk_role` must be
  # total; `kiosk-test-support/spec/demo_roles_are_total_spec.rb` holds every demo's.
  it 'returns NO role when #kiosk_role answers nil, even with roles declared' do
    Kiosk.configure { |c| c.roles = %i[owner customer] }
    user    = FakeUser.new(id: user_id, kiosk_role: nil)
    request = FakeRequest.new(current_user: user)

    expect(adapter.verify(request).role).to be_nil
  end
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify Kiosk.configuration.user_id_column' do
  include_context 'with a Devise adapter'

  it 'defaults to :id' do
    user    = FakeUser.new(id: user_id)
    request = FakeRequest.new(current_user: user)

    expect(adapter.verify(request).user_id).to eq(user_id)
  end

  it 'honours a custom column' do
    Kiosk.configure { |c| c.user_id_column = :external_id }

    user_class = Class.new do
      attr_reader :external_id

      def initialize(external_id:) = @external_id = external_id
    end
    user    = user_class.new(external_id: 'ext-42')
    request = FakeRequest.new(current_user: user)

    expect(adapter.verify(request).user_id).to eq('ext-42')
  end
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify shipped wire — ActionDispatch::Request' do
  include_context 'with a Devise adapter'

  # kiosk-server's WireController does NOT pass `self`; it passes
  # `request` (an ActionDispatch::Request) to
  # `IdentityResolution.resolve(request)`. That object has no
  # `#current_user` and is not a Hash — the adapter must read the
  # signed-in user from its Warden proxy at `request.env["warden"].user`,
  # or every Devise-session human 401s on the real wire.
  it "resolves an Identity from the request's Warden user" do
    user    = FakeUser.new(id: user_id)
    request = FakeActionDispatchRequest.new(warden: FakeWarden.new(user: user))

    identity = adapter.verify(request)

    expect(identity).to be_a(Kiosk::Identity)
    expect(identity.user_id).to eq(user_id)
    expect(identity.actor).to eq('human')
  end

  it 'returns nil when the request carries a Warden proxy with no signed-in user' do
    request = FakeActionDispatchRequest.new(warden: FakeWarden.new(user: nil))

    expect(adapter.verify(request)).to be_nil
  end

  it 'returns nil when the request env has no Warden proxy at all' do
    request = FakeActionDispatchRequest.new(warden: nil)

    expect(adapter.verify(request)).to be_nil
  end
end

RSpec.describe Kiosk::UserIdentityProviders::Devise, '#verify Rack env shim' do
  include_context 'with a Devise adapter'

  it "reads the user from env['warden'].user when the request is a Hash" do
    user   = FakeUser.new(id: user_id)
    warden = double('Warden::Proxy', user: user)
    env    = { 'warden' => warden }

    identity = adapter.verify(env)
    expect(identity.user_id).to eq(user_id)
  end

  it 'returns nil for a Hash env that has no warden entry' do
    expect(adapter.verify({})).to be_nil
  end
end
