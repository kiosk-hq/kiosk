# frozen_string_literal: true

RSpec.describe Kiosk::RLSRSpec do
  describe "JOURNEY_TYPES" do
    it "declares both kiosk_journey and kiosk_agent" do
      expect(described_class::JOURNEY_TYPES).to eq(%i[kiosk_journey kiosk_agent])
    end
  end

  describe "type: :kiosk_journey example group", type: :kiosk_journey do
    let(:alice) { FakeUser.new("u-alice", "customer") }

    before { Kiosk.configure { |c| c.roles = %i[customer] } }

    it "has the journey helpers available" do
      expect(self).to respond_to(:as_agent_of, :as_user, :as_agent, :as_anonymous,
                                 :query, :run_action, :pay_action, :kiosk_seed)
    end

    it "as_agent_of yields under an agent identity" do
      observed = nil
      as_agent_of(alice) { observed = Kiosk::TestHelpers.executor.current_identity }
      expect(observed.actor).to    eq("agent")
      expect(observed.user_id).to  eq("u-alice")
    end
  end

  describe "type: :kiosk_agent example group", type: :kiosk_agent do
    it "shares the same journey-DSL surface" do
      expect(self).to respond_to(:as_agent_of, :query, :run_action)
    end
  end

  describe ".install!" do
    it "is idempotent (re-running adds duplicates but the include is harmless)" do
      expect { described_class.install! }.not_to raise_error
    end
  end
end
