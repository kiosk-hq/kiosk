# frozen_string_literal: true

RSpec.describe Kiosk::UserIdentityProviders::Devise do
  subject(:adapter) { described_class.new }

  let(:user_id) { "11111111-1111-1111-1111-111111111111" }

  before { Kiosk.configure { |c| c.roles = %i[customer master] } }

  describe "#verify" do
    context "when current_user is present" do
      let(:user)    { FakeUser.new(id: user_id) }
      let(:request) { FakeRequest.new(current_user: user) }

      it "returns a Kiosk::Identity with the user's id" do
        identity = adapter.verify(request)

        expect(identity).to be_a(Kiosk::Identity)
        expect(identity.user_id).to eq(user_id)
      end

      it "marks the identity as a human actor (no agent_id)" do
        identity = adapter.verify(request)

        expect(identity.actor).to    eq("human")
        expect(identity.agent_id).to be_nil
        expect(identity).to          be_human
      end

      it "passes through an empty claims hash (Devise has no extra claims)" do
        expect(adapter.verify(request).claims).to eq({})
      end
    end

    context "when current_user is nil" do
      let(:request) { FakeRequest.new(current_user: nil) }

      it "returns nil (covers unauthenticated, locked, and unconfirmed uniformly)" do
        # Devise's `active_for_authentication?` already gates `current_user`,
        # so a locked or unconfirmed user yields `current_user == nil` —
        # one signal, three failure modes, no extra branching in the adapter.
        expect(adapter.verify(request)).to be_nil
      end
    end

    context "role resolution" do
      it "uses #kiosk_role when the user model defines it" do
        user    = FakeUser.new(id: user_id, kiosk_role: :master)
        request = FakeRequest.new(current_user: user)

        expect(adapter.verify(request).role).to eq("master")
      end

      it "falls back to the first symbol in Kiosk.configuration.roles" do
        user    = FakeUser.new(id: user_id)
        request = FakeRequest.new(current_user: user)

        expect(adapter.verify(request).role).to eq("customer")
      end

      it "raises ConfigurationError when roles is empty AND #kiosk_role is undefined" do
        Kiosk.configure { |c| c.roles = [] }
        user    = FakeUser.new(id: user_id)
        request = FakeRequest.new(current_user: user)

        expect { adapter.verify(request) }.to raise_error(
          described_class::ConfigurationError,
          /Cannot resolve a role.*kiosk_role/m,
        )
      end

      it "does NOT raise when roles is empty but #kiosk_role IS defined" do
        Kiosk.configure { |c| c.roles = [] }
        user    = FakeUser.new(id: user_id, kiosk_role: :customer)
        request = FakeRequest.new(current_user: user)

        expect(adapter.verify(request).role).to eq("customer")
      end
    end

    context "Kiosk.configuration.user_id_column" do
      it "defaults to :id" do
        user    = FakeUser.new(id: user_id)
        request = FakeRequest.new(current_user: user)

        expect(adapter.verify(request).user_id).to eq(user_id)
      end

      it "honours a custom column" do
        Kiosk.configure { |c| c.user_id_column = :external_id }

        user_class = Class.new do
          attr_reader :external_id
          def initialize(external_id:); @external_id = external_id; end
        end
        user    = user_class.new(external_id: "ext-42")
        request = FakeRequest.new(current_user: user)

        expect(adapter.verify(request).user_id).to eq("ext-42")
      end
    end

    context "Rack env shim" do
      it "reads the user from env['warden'].user when the request is a Hash" do
        user   = FakeUser.new(id: user_id)
        warden = double("Warden::Proxy", user: user)
        env    = { "warden" => warden }

        identity = adapter.verify(env)
        expect(identity.user_id).to eq(user_id)
      end

      it "returns nil for a Hash env that has no warden entry" do
        expect(adapter.verify({})).to be_nil
      end
    end
  end

  describe "#user_active?" do
    # Inherits the default from {Kiosk::UserIdentityProviders::Base} — in
    # embedded mode we rely on Devise's per-request `active_for_authentication?`
    # hook instead of this opt-in callback.
    it "returns true (default — embedded mode relies on Devise's per-request hook)" do
      expect(adapter.user_active?(user_id)).to be(true)
    end
  end
end
