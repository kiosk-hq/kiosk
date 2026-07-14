# frozen_string_literal: true

RSpec.describe Kiosk::Configuration do
  describe "defaults" do
    subject(:config) { described_class.new }

    it "defaults user_id_type to :uuid" do
      expect(config.user_id_type).to eq(:uuid)
    end

    it "defaults user_id_column to :id" do
      expect(config.user_id_column).to eq(:id)
    end

    it "defaults guc_namespace to 'app'" do
      expect(config.guc_namespace).to eq("app")
    end

    it "defaults roles to empty array" do
      expect(config.roles).to eq([])
    end

    it "leaves user_model nil (resolved at runtime by kiosk-server)" do
      expect(config.user_model).to be_nil
    end

    it "leaves issuer nil (provider must set)" do
      expect(config.issuer).to be_nil
    end

    it "leaves user_idp nil (satellite mode; kiosk:install writes a commented-out Devise line to uncomment)" do
      expect(config.user_idp).to be_nil
    end

    it "leaves agent_idp nil (kiosk-server falls back to the bundled DefaultAgentIdp per ADR-0013)" do
      expect(config.agent_idp).to be_nil
    end

    it "defaults schema to 'kiosk'" do
      expect(config.schema).to eq("kiosk")
    end

    it "defaults app_role to 'app_role'" do
      expect(config.app_role).to eq("app_role")
    end
  end

  describe "#schema" do
    it "is settable via Kiosk.configure" do
      Kiosk.configure { |c| c.schema = "agent_surface" }
      expect(Kiosk.configuration.schema).to eq("agent_surface")
    end
  end

  describe "#app_role" do
    it "is settable via Kiosk.configure" do
      Kiosk.configure { |c| c.app_role = "agent_role" }
      expect(Kiosk.configuration.app_role).to eq("agent_role")
    end
  end

  describe "#payment_provider" do
    it "defaults to nil" do
      expect(Kiosk.configuration.payment_provider).to be_nil
    end

    it "is configurable via Kiosk.configure" do
      provider = Object.new
      Kiosk.configure { |c| c.payment_provider = provider }
      expect(Kiosk.configuration.payment_provider).to be(provider)
    end
  end

  describe "#guc" do
    it "composes a full GUC name using the configured namespace" do
      config = described_class.new
      expect(config.guc(Kiosk::GUC::USER_ID)).to eq("app.current_user_id")
    end

    it "reflects an override of guc_namespace" do
      config = described_class.new
      config.guc_namespace = "kiosk"
      expect(config.guc(Kiosk::GUC::USER_ID)).to eq("kiosk.current_user_id")
    end
  end
end

RSpec.describe Kiosk do
  describe ".configure" do
    it "yields the configuration to the block" do
      yielded = nil
      described_class.configure { |c| yielded = c }
      expect(yielded).to be_a(Kiosk::Configuration)
    end

    it "persists configuration changes" do
      described_class.configure do |c|
        c.issuer = "https://acme.example"
        c.roles  = %i[customer support]
      end

      expect(described_class.configuration.issuer).to eq("https://acme.example")
      expect(described_class.configuration.roles).to  eq(%i[customer support])
    end

    it "returns the same configuration instance on repeated reads" do
      a = described_class.configuration
      b = described_class.configuration
      expect(a).to equal(b)
    end
  end

  describe ".reset!" do
    it "replaces configuration with a fresh default instance" do
      described_class.configure { |c| c.issuer = "https://acme.example" }
      described_class.reset!
      expect(described_class.configuration.issuer).to be_nil
    end
  end
end
