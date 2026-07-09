# frozen_string_literal: true

RSpec.describe Kiosk::RLS::ConfigurationExtension do
  describe "defaults" do
    subject(:config) { Kiosk.configuration }

    it "defaults system_role to 'system_role'" do
      expect(config.system_role).to eq("system_role")
    end
  end

  describe "overrides" do
    it "allows system_role to be set via Kiosk.configure" do
      Kiosk.configure { |c| c.system_role = "owner_role" }
      expect(Kiosk.configuration.system_role).to eq("owner_role")
    end
  end

  describe "reset behaviour" do
    it "Kiosk.reset! returns system_role to its default" do
      Kiosk.configure { |c| c.system_role = "owner_role" }
      Kiosk.reset!
      expect(Kiosk.configuration.system_role).to eq("system_role")
    end
  end
end
