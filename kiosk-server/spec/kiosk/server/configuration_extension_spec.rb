# frozen_string_literal: true

RSpec.describe Kiosk::Server::ConfigurationExtension do
  describe "defaults" do
    it "defaults mount_path to the Protocol's default mount path" do
      expect(Kiosk.configuration.mount_path).to eq("/kiosk")
    end

    # capabilities is COMPUTED from the live registry (ADR-0009): with nothing
    # registered and no payment provider, the endpoint advertises no verbs.
    it "computes capabilities as empty when no queries/actions/payments exist" do
      expect(Kiosk.configuration.capabilities).to eq([])
    end

    it "freezes the computed capabilities array" do
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

    it "lets capabilities be pinned explicitly (returned verbatim, bypasses computation)" do
      Kiosk::Server::Queries.register("q") { [] }
      Kiosk.configure { |c| c.capabilities = %w[schema query] }
      expect(Kiosk.configuration.capabilities).to eq(%w[schema query])
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

  # ─── computed capabilities (ADR-0009) ──────────────────────────────────
  # Members are verb names actually served, drawn from schema/query/run/pay
  # and emitted in that order. Derived from the live registry so discovery
  # never advertises a verb the provider has not wired.
  describe "#capabilities (computed)" do
    it "includes schema + query when only a query is registered" do
      Kiosk::Server::Queries.register("catalog") { [] }
      expect(Kiosk.configuration.capabilities).to eq(%w[schema query])
    end

    it "includes schema + run when only an action is registered" do
      Kiosk::Server::Actions.register("checkout") { {} }
      expect(Kiosk.configuration.capabilities).to eq(%w[schema run])
    end

    it "includes pay when a payment provider is configured" do
      Kiosk.configure { |c| c.payment_provider = Object.new }
      expect(Kiosk.configuration.capabilities).to eq(%w[pay])
    end

    it "emits the full set in canonical order schema, query, run, pay" do
      Kiosk::Server::Queries.register("catalog") { [] }
      Kiosk::Server::Actions.register("checkout") { {} }
      Kiosk.configure { |c| c.payment_provider = Object.new }
      expect(Kiosk.configuration.capabilities).to eq(%w[schema query run pay])
    end

    it "never encodes HTTP methods" do
      Kiosk::Server::Queries.register("catalog") { [] }
      expect(Kiosk.configuration.capabilities).not_to include("GET", "POST")
    end
  end

  describe "reset" do
    it "Kiosk.reset! returns server-specific fields to defaults" do
      Kiosk.configure { |c| c.mount_path = "/elsewhere" }
      Kiosk.reset!
      expect(Kiosk.configuration.mount_path).to eq("/kiosk")
    end
  end

  describe "stacking on kiosk-core configuration" do
    it "exposes kiosk-core's schema/app_role attrs (no kiosk-rls needed)" do
      expect(Kiosk.configuration.schema).to   eq("kiosk")
      expect(Kiosk.configuration.app_role).to eq("app_role")
    end
  end

  describe "#enforce_db_role" do
    it "defaults to false" do
      expect(Kiosk.configuration.enforce_db_role).to be(false)
    end

    it "is settable via Kiosk.configure" do
      Kiosk.configure { |c| c.enforce_db_role = true }
      expect(Kiosk.configuration.enforce_db_role).to be(true)
    end
  end

  describe "signing_key" do
    # RSA generation is ~100ms; cache one for the whole context.
    let(:rsa)         { OpenSSL::PKey::RSA.generate(2048) }
    let(:signing_key) { Kiosk::Server::SigningKey.new(rsa) }

    # Scrub BOTH env vars so these examples behave identically on machines
    # that keep KIOSK_SIGNING_KEY_B64 in their env (mise.toml [env]) and on
    # clean ones. Restore-or-delete in ensure so examples that set a var
    # inside their body don't leak it into later examples.
    around do |example|
      original_pem = ENV.delete("KIOSK_SIGNING_KEY_PEM")
      original_b64 = ENV.delete("KIOSK_SIGNING_KEY_B64")
      example.run
    ensure
      original_pem ? ENV["KIOSK_SIGNING_KEY_PEM"] = original_pem : ENV.delete("KIOSK_SIGNING_KEY_PEM")
      original_b64 ? ENV["KIOSK_SIGNING_KEY_B64"] = original_b64 : ENV.delete("KIOSK_SIGNING_KEY_B64")
    end

    it "raises with generation instructions when no key is configured and no env var is set" do
      expect {
        Kiosk.configuration.signing_key
      }.to raise_error(RuntimeError, /KIOSK_SIGNING_KEY_PEM or KIOSK_SIGNING_KEY_B64 is required/)
    end

    it "memoises the env-resolved key across accesses" do
      ENV["KIOSK_SIGNING_KEY_PEM"] = rsa.to_pem
      Kiosk.reset!
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

    it "honours KIOSK_SIGNING_KEY_B64 env var for default resolution" do
      require "base64"
      ENV["KIOSK_SIGNING_KEY_B64"] = Base64.strict_encode64(rsa.to_pem)
      Kiosk.reset!
      expect(Kiosk.configuration.signing_key.kid).to eq(signing_key.kid)
    end

    it "Kiosk.reset! drops any configured key (next access without env raises)" do
      Kiosk.configure { |c| c.signing_key = signing_key }
      Kiosk.reset!
      expect {
        Kiosk.configuration.signing_key
      }.to raise_error(RuntimeError, /KIOSK_SIGNING_KEY_PEM or KIOSK_SIGNING_KEY_B64 is required/)
    end
  end
end
