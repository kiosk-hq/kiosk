# frozen_string_literal: true

RSpec.describe Kiosk::GUC do
  describe "constants" do
    it "exposes the four well-known suffix names" do
      expect(described_class::USER_ID).to  eq("current_user_id")
      expect(described_class::ROLE).to     eq("current_role")
      expect(described_class::ACTOR).to    eq("current_actor")
      expect(described_class::AGENT_ID).to eq("current_agent_id")
    end

    it "defaults namespace to 'app'" do
      expect(described_class::DEFAULT_NAMESPACE).to eq("app")
    end
  end

  describe ".for" do
    it "composes namespace and suffix with a dot" do
      expect(described_class.for("app", described_class::USER_ID))
        .to eq("app.current_user_id")
      expect(described_class.for("kiosk", described_class::AGENT_ID))
        .to eq("kiosk.current_agent_id")
    end
  end
end
