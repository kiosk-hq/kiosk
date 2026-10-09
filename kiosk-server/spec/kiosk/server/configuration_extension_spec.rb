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

    # K-1399. The two validation flags point OPPOSITE ways on purpose, and the
    # pair is asserted together because the asymmetry is the whole content of
    # the decision: a request-shape refusal is a 400 to a caller who sent a bad
    # request; a response-shape refusal is a 500 to a caller who did nothing
    # wrong. `validate_requests` shipped false while all seven showcases and the
    # install generator turned it on — a default nobody wanted, whose off-state
    # failure is SILENT (the K-479 re-challenge loop).
    describe "the two validation flags" do
      it "defaults validate_requests to TRUE and validate_responses to FALSE" do
        expect(Kiosk.configuration.validate_requests).to  be(true)
        expect(Kiosk.configuration.validate_responses).to be(false)
      end

      # The reader must not be an `||=`: with a true default that idiom turns an
      # operator's explicit `false` back into `true` and the opt-out silently
      # does nothing — the same silence the flip exists to remove.
      it "lets an operator turn validate_requests OFF and keeps it off" do
        Kiosk.configure { |c| c.validate_requests = false }
        expect(Kiosk.configuration.validate_requests).to be(false)
      end
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
      Kiosk.configure { |c| c.min_client = "0.9.0" }
      expect(Kiosk.configuration.min_client).to eq("0.9.0")
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
    # exactly this). The REASON changed on 2026-08-19 and the property did
    # not: the verb names are public now (`GET <endpoint>/schema` at T-094,
    # `openapi.json` at K-804, `/.well-known/api-catalog` at T-093), so this
    # example is no longer about withholding anything. It is about there being
    # ONE source of truth for the verb list — the catalog — which this
    # document points at rather than copies.
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

    it "raises when no key is configured" do
      expect { Kiosk.configuration.signing_key }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /c.signing_key is not set/)
    end

    it "does not read the environment" do
      ENV["KIOSK_SIGNING_KEY_PEM"] = rsa.to_pem
      expect { Kiosk.configuration.signing_key }.to raise_error(Kiosk::Server::Errors::ConfigurationError)
    ensure
      ENV.delete("KIOSK_SIGNING_KEY_PEM")
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

    it "Kiosk.reset! drops any configured key" do
      Kiosk.configure { |c| c.signing_key = signing_key }
      Kiosk.reset!
      expect { Kiosk.configuration.signing_key }.to raise_error(Kiosk::Server::Errors::ConfigurationError)
    end
  end

  describe "pow_secret" do
    it "refuses a secret shorter than 32 bytes" do
      expect { Kiosk.configure { |c| c.pow_secret = "short" } }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /at least 32 bytes \(got 5\)/)
    end

    it "accepts 32 bytes" do
      Kiosk.configure { |c| c.pow_secret = "x" * 32 }
      expect(Kiosk.configuration.pow_secret).to eq("x" * 32)
    end
  end
  # ─── a lazy STORE default is allocated exactly once ────────────────────────
  #
  # `@x ||= Store.new` with no lock lets racing first-touchers each build a
  # store of their own. These examples force that interleaving — see
  # `with_slow_store_allocation` in spec_helper.
  describe "lazy store defaults under a concurrent first touch" do
    # Every slot here is stateful: what the losers of the race record is lost
    # when the last write lands, and for `pow_spent_store` what is lost is the
    # spent-id set that makes a proof of work single-use.
    {
      pow_spent_store:             Kiosk::Server::PowSpentStores::ActiveRecord,
      auth_challenge_store:        Kiosk::Server::AuthChallengeStore,
      revocation_store:            Kiosk::Server::RevocationStore,
      device_authorization_store:  Kiosk::Server::DeviceAuthorizationStores::ActiveRecord,
    }.each do |slot, klass|
      it "hands #{slot} to 20 racing threads as ONE #{klass.name.split("::").last} object" do
        Kiosk.reset!
        stores = with_slow_store_allocation { race(20) { Kiosk.configuration.public_send(slot) } }

        expect(stores.uniq.length).to eq(1)
        expect(stores.first).to be_a(klass)
      end
    end

    it "does not re-default revocation_store when an operator set it to nil" do
      Kiosk.configure { |c| c.revocation_store = nil }
      stores = with_slow_store_allocation { race(20) { Kiosk.configuration.revocation_store } }

      expect(stores.uniq).to eq([nil])
    end

    # The census, not a list: every lazy default in the shipped file that
    # ALLOCATES a store must take the lock. A new store slot added later
    # without it reddens here, which is the property a hand-kept list of four
    # names cannot buy.
    describe "the guarded set is derived from the shipped source" do
      source_path = Kiosk::Server::ConfigurationExtension
                    .instance_method(:pow_spent_store).source_location.first
      source      = File.read(source_path)
      # `def <name>` with no arguments, through its matching `end` at the same
      # indent — the shape every lazy default in this file is written in.
      methods     = source.scan(/^      def ([a-z_0-9]+)\n(.*?)^      end$/m).to_h
      allocating  = methods.select { |_, body| body.match?(/Store[A-Za-z:]*\.new|Stores::[A-Za-z:]+\.new/) }

      # Vacuity arm: if the scan above stops matching (a reindent, a rewrite)
      # the census below passes on an empty set and says nothing. Fail instead.
      it "finds the store-allocating lazy defaults at all" do
        expect(allocating.keys).to include(
          "pow_spent_store", "auth_challenge_store", "revocation_store", "device_authorization_store"
        )
      end

      allocating.each_key do |name|
        it "#{name} serialises its first touch on LAZY_STORE_MUTEX" do
          expect(allocating.fetch(name)).to include("LAZY_STORE_MUTEX")
        end
      end
    end
  end
end
