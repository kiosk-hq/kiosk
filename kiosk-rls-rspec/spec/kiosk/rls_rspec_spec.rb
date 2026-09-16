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
      helpers = %i[as_agent_of as_user as_agent as_anonymous
                   query run_query run_action pay_action kiosk_seed]

      # The list is hand-kept, so hold it to the MODULE rather than to itself.
      # It was short by `run_query` for as long as that method existed, and a
      # `respond_to` over a short list passes whether or not the missing helper
      # is mixed in at all — the one thing this example exists to catch.
      expect(helpers).to match_array(Kiosk::TestHelpers::Journey.public_instance_methods(false))
      expect(self).to respond_to(*helpers)
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
      # «The same surface» is the whole claim, so ask the module for it — three
      # sampled names could not tell a shared surface from a subset of one.
      expect(self).to respond_to(*Kiosk::TestHelpers::Journey.public_instance_methods(false))
    end
  end

  describe ".install!" do
    it "is idempotent (re-running adds duplicates but the include is harmless)" do
      expect { described_class.install! }.not_to raise_error
    end
  end
end
