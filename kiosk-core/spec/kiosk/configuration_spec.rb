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

    it "leaves agent_idp nil (kiosk-server falls back to the bundled DefaultAgentIdp)" do
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

  # ─── K-1619: the configuration memo is built exactly once ──────────────────
  #
  # `@configuration ||= Configuration.new` was a read, an allocation and a
  # write with no lock between them, so N threads racing the FIRST read each
  # built a Configuration of their own and the last write discarded the rest —
  # the same seam K-1610 closed one level down on kiosk-server's four lazy
  # store slots, and strictly worse, because every setting diverges at once
  # rather than one spent-id set.
  #
  # These examples FORCE the interleaving rather than hoping for it: the window
  # is sub-microsecond and K-1610 measured 0 failures in 2000 trials of the
  # identical shape. `with_slow_configuration_allocation` slows the allocation
  # itself, which releases the GVL exactly inside it.
  describe "the lazy configuration memo under a concurrent first touch (K-1619)" do
    before { described_class.instance_variable_set(:@configuration, nil) }

    it "hands 20 racing first-touchers ONE Configuration, built once" do
      configs, built = with_slow_configuration_allocation { race(20) { described_class.configuration } }

      expect(built).to eq(1)
      expect(configs.uniq.length).to eq(1)
      expect(configs.first).to be_a(Kiosk::Configuration)
    end

    # The harm, not just the duplicate: what a losing copy was configured with
    # is thrown away when the last write lands. Pre-fix each thread appends to
    # a `roles` array of its own and the survivor carries ONE entry.
    it "does not discard what a racing first-toucher wrote" do
      appends = Mutex.new
      _, built = with_slow_configuration_allocation do
        race(20) do
          config = described_class.configuration
          appends.synchronize { config.roles << :seen }
        end
      end

      expect(built).to eq(1)
      expect(described_class.configuration.roles.length).to eq(20)
    end

    # The census, not a list: every module-level lazy memo in the shipped file
    # must take the lock. One added later without it reddens here.
    describe "the guarded set is derived from the shipped source" do
      source_path = Kiosk.method(:configuration).source_location.first
      source      = File.read(source_path)
      # `def self.<name>` with no arguments, through its matching `end` at the
      # same indent — the shape every module-level default in this file uses.
      methods     = source.scan(/^  def self\.([a-z_0-9]+)\n(.*?)^  end$/m).to_h
      memoising   = methods.select { |_, body| body.match?(/@[a-z_0-9]+ \|\|=/) }

      # Vacuity arm: if the scan above stops matching (a reindent, a rewrite)
      # the census below passes on an empty set and says nothing. Fail instead.
      it "finds the memoising module-level defaults at all" do
        expect(memoising.keys).to include("configuration")
      end

      memoising.each_key do |name|
        it "#{name} serialises its first touch on CONFIGURATION_MUTEX" do
          expect(memoising.fetch(name)).to include("CONFIGURATION_MUTEX")
        end
      end
    end
  end
end
