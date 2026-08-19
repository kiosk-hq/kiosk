# frozen_string_literal: true

RSpec.describe Kiosk::Server::ConfigurationExtension do
  describe "defaults" do
    it "defaults mount_path to the Protocol's default mount path" do
      expect(Kiosk.configuration.mount_path).to eq("/kiosk")
    end

    # capabilities is COMPUTED from the live registry: with nothing
    # registered and no payment provider, the endpoint advertises no modules.
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

    # The auth-challenge nonce must outlive the registration PoW solve,
    # or a slow honest solver's nonce expires mid-solve (and the proofs are
    # already burned). The PoW solve window is pow_ttl * count.
    describe "auth_challenge_ttl vs the registration PoW solve window" do
      it "defaults to comfortably exceed a single-proof PoW window (count treated as >= 1)" do
        c = Kiosk.configuration
        expect(c.auth_challenge_ttl).to be > c.pow_ttl
      end

      it "exceeds the full PoW window pow_ttl * registration_pow_count" do
        Kiosk.configure { |cfg| cfg.registration_pow_count = 3 }
        c = Kiosk.configuration
        expect(c.auth_challenge_ttl).to be >= c.pow_ttl * c.registration_pow_count
      end

      it "scales when pow_ttl is raised" do
        Kiosk.configure { |cfg| cfg.pow_ttl = 600 }
        c = Kiosk.configuration
        expect(c.auth_challenge_ttl).to be > c.pow_ttl
      end

      it "still honours an explicit override" do
        Kiosk.configure { |cfg| cfg.auth_challenge_ttl = 45 }
        expect(Kiosk.configuration.auth_challenge_ttl).to eq(45)
      end
    end
  end

  describe "overrides" do
    it "lets mount_path be set via Kiosk.configure" do
      Kiosk.configure { |c| c.mount_path = "/agent-surface" }
      expect(Kiosk.configuration.mount_path).to eq("/agent-surface")
    end

    it "lets capabilities be pinned explicitly (returned verbatim, bypasses computation)" do
      declare_query("q")
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

  # ─── computed capabilities ──────────────────────────────────
  # Members are MODULE names actually served, drawn from
  # schema/queries/actions/pay and emitted in that order (T-075 = A,
  # ADR-0025). Derived from the live registry so discovery never advertises a
  # module the provider has not wired.
  describe "#capabilities (computed)" do
    it "includes schema + queries when only a query is registered" do
      declare_query("catalog")
      expect(Kiosk.configuration.capabilities).to eq(%w[schema queries])
    end

    it "includes schema + actions when only an action is registered" do
      declare_action("checkout")
      expect(Kiosk.configuration.capabilities).to eq(%w[schema actions])
    end

    it "includes pay when a payment provider is configured" do
      Kiosk.configure { |c| c.payment_provider = Object.new }
      expect(Kiosk.configuration.capabilities).to eq(%w[pay])
    end

    it "emits the full set in canonical order schema, queries, actions, pay" do
      declare_query("catalog")
      declare_action("checkout")
      Kiosk.configure { |c| c.payment_provider = Object.new }
      expect(Kiosk.configuration.capabilities).to eq(%w[schema queries actions pay])
    end

    it "never encodes HTTP methods" do
      declare_query("catalog")
      expect(Kiosk.configuration.capabilities).not_to include("GET", "POST")
    end

    # THE PROPERTY THE MODULE-NAME ANSWER BOUGHT (T-075 = A rejected B for
    # exactly this): `/.well-known/kiosk.json` is unauthenticated, so whatever
    # lands in `capabilities` is public. A registered verb NAME must never be
    # among it — the catalog is Bearer-gated behind `GET <endpoint>/schema`,
    # and a discovery document that leaked the names would hand an anonymous
    # prober the enumeration three separate defences exist to withhold.
    it "never leaks a registered verb name" do
      declare_query("secret_pricing_tiers")
      declare_action("cancel_enterprise_contract")
      Kiosk.configure { |c| c.payment_provider = Object.new }
      caps = Kiosk.configuration.capabilities
      expect(caps).to eq(%w[schema queries actions pay])
      expect(caps).not_to include("secret_pricing_tiers", "cancel_enterprise_contract")
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

  describe "#sign_in_path" do
    it "defaults to nil (engine stays IdP-neutral; bare 401 preserved)" do
      expect(Kiosk.configuration.sign_in_path).to be_nil
    end

    it "is settable via Kiosk.configure (operator's own sign-in URL)" do
      Kiosk.configure { |c| c.sign_in_path = "/users/sign_in" }
      expect(Kiosk.configuration.sign_in_path).to eq("/users/sign_in")
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
