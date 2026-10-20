# frozen_string_literal: true

RSpec.describe Kiosk::Configuration do
  describe 'defaults' do
    subject(:config) { described_class.new }

    it 'defaults user_id_type to :uuid' do
      expect(config.user_id_type).to eq(:uuid)
    end

    it 'defaults roles to empty array' do
      expect(config.roles).to eq([])
    end

    it "defaults app_role to 'app_role'" do
      expect(config.app_role).to eq('app_role')
    end

    it 'leaves user_model nil (resolved at runtime by kiosk-server)' do
      expect(config.user_model).to be_nil
    end

    it 'leaves issuer nil (provider must set)' do
      expect(config.issuer).to be_nil
    end

    it 'leaves user_idp nil (satellite mode; kiosk:install writes a commented-out Devise line to uncomment)' do
      expect(config.user_idp).to be_nil
    end

    it 'leaves agent_idp nil (kiosk-server falls back to the bundled DefaultAgentIdp)' do
      expect(config.agent_idp).to be_nil
    end
  end

  describe '#app_role' do
    it 'is settable via Kiosk.configure' do
      Kiosk.configure { |c| c.app_role = 'agent_role' }
      expect(Kiosk.configuration.app_role).to eq('agent_role')
    end
  end

  describe '#payment_provider' do
    it 'defaults to nil' do
      expect(Kiosk.configuration.payment_provider).to be_nil
    end

    it 'is configurable via Kiosk.configure' do
      provider = Object.new
      Kiosk.configure { |c| c.payment_provider = provider }
      expect(Kiosk.configuration.payment_provider).to be(provider)
    end
  end

  describe Kiosk do
    describe '.configure' do
      it 'yields the configuration to the block' do
        yielded = nil
        described_class.configure { |c| yielded = c }
        expect(yielded).to be_a(Kiosk::Configuration)
      end

      it 'persists configuration changes' do
        described_class.configure do |c|
          c.issuer = 'https://acme.example'
          c.roles  = %i[customer support]
        end

        expect(described_class.configuration.issuer).to eq('https://acme.example')
        expect(described_class.configuration.roles).to  eq(%i[customer support])
      end

      it 'returns the same configuration instance on repeated reads' do
        a = described_class.configuration
        b = described_class.configuration
        expect(a).to equal(b)
      end
    end

    describe '.reset!' do
      it 'replaces configuration with a fresh default instance' do
        described_class.configure { |c| c.issuer = 'https://acme.example' }
        described_class.reset!
        expect(described_class.configuration.issuer).to be_nil
      end
    end

    # The configuration memo is built exactly once, even when many threads touch
    # it first at the same time. `with_slow_configuration_allocation` slows the
    # allocation, which releases the GVL inside the window and forces the race.
    describe 'the lazy configuration memo under a concurrent first touch (K-1619)' do
      before { described_class.instance_variable_set(:@configuration, nil) }

      it 'hands 20 racing first-touchers ONE Configuration, built once' do
        configs, built = with_slow_configuration_allocation { race(20) { described_class.configuration } }

        expect(built).to eq(1)
        expect(configs.uniq.length).to eq(1)
        expect(configs.first).to be_a(Kiosk::Configuration)
      end

      # A losing copy would lose what was written to it. Each thread appends to
      # `roles`, so the survivor must carry every entry.
      it 'does not discard what a racing first-toucher wrote' do
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
    end

    # Every module-level lazy memo in the shipped file must take the lock.
    describe 'the guarded set of the lazy memos is derived from the shipped source' do
      source_path = described_class.method(:configuration).source_location.first
      # `def self.<name>` with no arguments, through its matching `end` at the
      # same indent: the shape every module-level default in this file uses.
      methods     = File.read(source_path).scan(/^  def self\.([a-z_0-9]+)\n(.*?)^  end$/m).to_h
      memoising   = methods.select { |_, body| body.match?(/@[a-z_0-9]+ \|\|=/) }

      # If the scan stops matching, the census below passes on an empty set.
      it 'finds the memoising module-level defaults at all' do
        expect(memoising.keys).to include('configuration')
      end

      memoising.each_key do |name|
        it "#{name} serialises its first touch on CONFIGURATION_MUTEX" do
          expect(memoising.fetch(name)).to include('CONFIGURATION_MUTEX')
        end
      end
    end
  end
end
