# frozen_string_literal: true

RSpec.describe Kiosk::Server::ConfigurationExtension do
  describe "defaults" do
    it "defaults mount_path to the Protocol's default mount path" do
      expect(Kiosk.configuration.mount_path).to eq("/kiosk")
    end

    it "defaults capabilities to the MVP-complete set" do
      expect(Kiosk.configuration.capabilities).to eq(%w[sql actions ap2 events])
    end

    it "freezes the default capabilities array" do
      expect(Kiosk.configuration.capabilities).to be_frozen
    end

    it "defaults owner to an empty hash" do
      expect(Kiosk.configuration.owner).to eq({})
    end

    it "defaults min_client to the Protocol's MIN_CLIENT" do
      expect(Kiosk.configuration.min_client).to eq(Kiosk::Protocol::MIN_CLIENT)
    end
  end

  describe "overrides" do
    it "lets mount_path be set via Kiosk.configure" do
      Kiosk.configure { |c| c.mount_path = "/agent-surface" }
      expect(Kiosk.configuration.mount_path).to eq("/agent-surface")
    end

    it "lets capabilities be narrowed (providers shipping a subset)" do
      Kiosk.configure { |c| c.capabilities = %w[sql] }
      expect(Kiosk.configuration.capabilities).to eq(%w[sql])
    end

    it "lets owner be set" do
      Kiosk.configure { |c| c.owner = { name: "Acme Inc.", support: "support@acme.example" } }
      expect(Kiosk.configuration.owner[:name]).to eq("Acme Inc.")
    end

    it "lets min_client be bumped (provider requires newer CLI feature)" do
      Kiosk.configure { |c| c.min_client = "0.5.0" }
      expect(Kiosk.configuration.min_client).to eq("0.5.0")
    end
  end

  describe "reset" do
    it "Kiosk.reset! returns server-specific fields to defaults" do
      Kiosk.configure { |c| c.mount_path = "/elsewhere" }
      Kiosk.reset!
      expect(Kiosk.configuration.mount_path).to eq("/kiosk")
    end
  end

  describe "stacking with kiosk-rls extension" do
    it "still exposes kiosk-rls's schema/app_role/system_role attrs (extension stacking)" do
      expect(Kiosk.configuration.schema).to       eq("kiosk")
      expect(Kiosk.configuration.app_role).to     eq("app_role")
      expect(Kiosk.configuration.system_role).to  eq("system_role")
    end
  end

  describe "signing_key" do
    # RSA generation is ~100ms; cache one for the whole context.
    let(:rsa)         { OpenSSL::PKey::RSA.generate(2048) }
    let(:signing_key) { Kiosk::Server::SigningKey.new(rsa) }

    around do |example|
      original = ENV.delete("KIOSK_SIGNING_KEY_PEM")
      example.run
    ensure
      ENV["KIOSK_SIGNING_KEY_PEM"] = original if original
    end

    it "lazy-generates a fresh SigningKey when nothing is configured" do
      expect(Kiosk.configuration.signing_key).to be_a(Kiosk::Server::SigningKey)
      expect(Kiosk.configuration.signing_key).to be_private
    end

    it "memoises the generated key across accesses" do
      first  = Kiosk.configuration.signing_key
      second = Kiosk.configuration.signing_key
      expect(second).to equal(first)
    end

    it "accepts a SigningKey instance via the setter" do
      Kiosk.configure { |c| c.signing_key = signing_key }
      expect(Kiosk.configuration.signing_key).to equal(signing_key)
    end

    it "accepts a PEM string via the setter" do
      Kiosk.configure { |c| c.signing_key = rsa.to_pem }
      expect(Kiosk.configuration.signing_key.kid).to eq(signing_key.kid)
    end

    it "rejects an unrecognised type" do
      expect {
        Kiosk.configure { |c| c.signing_key = 42 }
      }.to raise_error(ArgumentError, /SigningKey or PEM string/)
    end

    it "honours KIOSK_SIGNING_KEY_PEM env var for default resolution" do
      ENV["KIOSK_SIGNING_KEY_PEM"] = rsa.to_pem
      Kiosk.reset!
      expect(Kiosk.configuration.signing_key.kid).to eq(signing_key.kid)
    end

    it "Kiosk.reset! drops any configured key" do
      Kiosk.configure { |c| c.signing_key = signing_key }
      Kiosk.reset!
      expect(Kiosk.configuration.signing_key).not_to equal(signing_key)
    end
  end
end
