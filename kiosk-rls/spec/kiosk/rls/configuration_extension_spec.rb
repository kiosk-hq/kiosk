# frozen_string_literal: true

RSpec.describe Kiosk::RLS::ConfigurationExtension do
  describe "defaults" do
    subject(:config) { Kiosk.configuration }

    it "defaults app_role to 'app_role'" do
      expect(config.app_role).to eq("app_role")
    end

    it "defaults system_role to 'system_role'" do
      expect(config.system_role).to eq("system_role")
    end

    it "defaults schema to 'kiosk'" do
      expect(config.schema).to eq("kiosk")
    end
  end

  describe "overrides" do
    it "allows app_role to be set via Kiosk.configure" do
      Kiosk.configure { |c| c.app_role = "agent_role" }
      expect(Kiosk.configuration.app_role).to eq("agent_role")
    end

    it "allows system_role to be set via Kiosk.configure" do
      Kiosk.configure { |c| c.system_role = "owner_role" }
      expect(Kiosk.configuration.system_role).to eq("owner_role")
    end

    it "allows schema to be set via Kiosk.configure (for providers whose primary backend already uses `kiosk`)" do
      Kiosk.configure { |c| c.schema = "ksk" }
      expect(Kiosk.configuration.schema).to eq("ksk")
    end
  end

  describe "reset behaviour" do
    it "Kiosk.reset! returns app_role to its default" do
      Kiosk.configure { |c| c.app_role = "agent_role" }
      Kiosk.reset!
      expect(Kiosk.configuration.app_role).to eq("app_role")
    end
  end
end
