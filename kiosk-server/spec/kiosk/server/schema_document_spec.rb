# frozen_string_literal: true

# The `schema` catalog and its boot digest.
#
# The document `GET <endpoint>/schema` serves, derived once from the registry
# + the origin config + the gem version, and the digest that travels as its
# strong ETag and as the `?v=` cache-buster in every discovery link.
#
# What is proved here is the thing the whole design rests on: **the digest
# moves whenever the bytes a client would cache could move, and does not move
# otherwise.** A digest narrower than that is a stale catalogue with a green
# check beside it.

RSpec.shared_context 'schema document spec: fresh catalog' do
  before do
    Kiosk.configure do |c|
      c.issuer = 'https://demo.example'
    end
    described_class.reset!
  end

  after { described_class.reset! }

  delegate :digest, to: :described_class
end

RSpec.describe Kiosk::Server::SchemaDocument do
  include_context 'schema document spec: fresh catalog'

  describe '.document' do
    it 'is exactly {queries, actions, events} — sorted descriptors, and NO `verbs`' do
      declare_query('menu', description: 'Browse the menu')
      declare_action('place_order', description: 'Place an order')

      document = described_class.document

      expect(document.keys).to eq(%i[queries actions events])
      expect(document[:queries].pluck(:name)).to eq(%w[menu])
      expect(document[:actions].pluck(:name)).to eq(%w[place_order])
    end

    # The module set belongs to `/.well-known/kiosk.json` alone.
    it 'does not republish the module set the discovery document owns' do
      declare_query('menu')

      expect(described_class.document).not_to have_key(:verbs)
      expect(described_class.json).not_to include('verbs')
      expect(Kiosk.configuration.capabilities).to include('schema')
    end

    it 'answers an origin with nothing registered, rather than refusing' do
      expect(described_class.document).to eq(queries: [], actions: [], events: [])
    end
  end

  describe '.digest' do
    it 'is 32 lowercase hex characters' do
      declare_query('menu')
      expect(digest).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'is STABLE across reads — the derivation happens once' do
      declare_query('menu')
      expect(digest).to eq(digest)
      expect(described_class.document).to equal(described_class.document)
    end

    # ── THE REGISTRY ────────────────────────────────────────────────────
    it 'moves when a verb is ADDED' do
      declare_query('menu')
      before_add = digest

      declare_query('specials')
      expect(digest).not_to eq(before_add)
    end

    it 'moves when a verb is REMOVED' do
      declare_query('menu')
      declare_query('specials')
      both = digest

      Kiosk::Server::Queries.unregister('specials')
      described_class.reset!
      expect(digest).not_to eq(both)
    end

    it 'moves when only a DESCRIPTION changes' do
      declare_query('menu', description: 'Generation 1.')
      first = digest

      Kiosk::Server::Queries.reset!
      described_class.reset!
      declare_query('menu', description: 'Generation 2.')
      expect(digest).not_to eq(first)
    end

    # ── THE ORIGIN CONFIG ───────────────────────────────────────────────
    it 'moves when the mount path moves' do
      declare_query('menu')
      before_move = digest

      Kiosk.configure { |c| c.mount_path = '/api/kiosk' }
      described_class.reset!
      expect(digest).not_to eq(before_move)
    end

    it 'moves when the skill pin is re-issued' do
      declare_query('menu')
      unpinned = digest

      Kiosk.configure { |c| c.skill_url = 'https://kiosk.tech/skill-v9.9.9.md' }
      described_class.reset!
      expect(digest).not_to eq(unpinned)
    end

    # ── THE GEM VERSION, which is the reason nothing is pre-generated ───
    #
    # A kiosk-server PATCH bump can change the renderer with the registry
    # untouched, so the digest must cover the gem version too.
    it "moves when kiosk-server's own version moves, with the registry untouched" do
      declare_query('menu')
      at_current = digest

      described_class.reset!
      stub_const('Kiosk::Server::VERSION', '9.9.9')
      expect(digest).not_to eq(at_current)
    end
  end

  describe '.etag' do
    it 'is the digest, quoted, and STRONG — no `W/` prefix' do
      declare_query('menu')
      expect(described_class.etag).to eq(%("#{digest}"))
      expect(described_class.etag).not_to start_with('W/')
    end
  end

  describe 'the boot contract' do
    it 'reports NOT derived before anything asks, and derived after derive!' do
      declare_query('menu')
      expect(described_class.derived?).to be(false)

      described_class.derive!
      expect(described_class.derived?).to be(true)
    end

    it "is dropped by reset! — the engine's to_prepare hook, for a dev reload" do
      declare_query('menu')
      described_class.derive!

      described_class.reset!
      expect(described_class.derived?).to be(false)
    end

    it 're-derives after a reset rather than serving the dropped memo' do
      declare_query('menu')
      first = digest

      Kiosk::Server::Queries.reset!
      described_class.reset!
      declare_query('brunch')

      expect(digest).not_to eq(first)
      expect(described_class.document[:queries].pluck(:name)).to eq(%w[brunch])
    end
  end

  describe 'when a descriptor slot is data-derived' do
    it 'moves the digest when the derived value changes, with no reset and no restart' do
      slugs = %w[bikes]
      Kiosk::Server::SchemaSlots.refresh_seconds = 0
      declare_query('board', input_schema: {
                      type: 'object', properties: { category: { enum: -> { slugs } } }
                    })
      first = digest

      slugs = %w[bikes free] # the operator adds a category

      expect(digest).not_to eq(first)
      expect(described_class.json).to include('"enum":["bikes","free"]')
    end

    it 'keeps the digest STABLE while the memo window holds' do
      slugs = %w[bikes]
      Kiosk::Server::SchemaSlots.refresh_seconds = 3600
      declare_query('board', input_schema: {
                      type: 'object', properties: { category: { enum: -> { slugs } } }
                    })
      first = digest
      slugs = %w[bikes free]

      expect(digest).to eq(first)
    end

    # The epoch is a MEMO key, not a digest input: an epoch that rolls while
    # the resolved value is unchanged must produce the SAME digest. Two
    # documents publish this digest (the `?v=` on the discovery link and the
    # catalog's strong ETag), and a client may read them in different
    # 60-second windows.
    it 'keeps the digest UNCHANGED across an epoch roll when the value has not moved' do
      slugs = %w[bikes]
      epoch = 1
      # Drive the epoch; do not wait for a 60-second bucket boundary.
      allow(Kiosk::Server::SchemaSlots).to receive(:epoch) { epoch }
      Kiosk::Server::SchemaSlots.refresh_seconds = 0 # never reuse a resolved value
      declare_query('board', input_schema: {
                      type: 'object', properties: { category: { enum: -> { slugs } } }
                    })
      first = digest

      epoch = 2 # the memo window rolled; the operator's data did not

      expect(digest).to eq(first)

      # ... and the roll really was rebuilding, not answering from a memo:
      # move the value under a third epoch and the digest follows.
      epoch = 3
      slugs = %w[bikes free]

      expect(digest).not_to eq(first)
    end

    # `after_initialize` runs on EVERY boot, `db:create` and `db:migrate`
    # included, and a proc that reads a table cannot succeed there. Eager
    # derivation is an optimisation, so it defers rather than taking the boot
    # down — and the failure is still visible, because `derived?` says so.
    it 'defers derivation instead of failing the boot when the data is unreachable' do
      declare_query('board', input_schema: {
                      type: 'object', properties: { category: { enum: -> { raise 'no table yet' } } }
                    })

      expect { described_class.derive! }.not_to raise_error
      expect(described_class.derived?).to be(false)
    end

    # The other half of that: an origin with NO proc anywhere touches no
    # database during derivation, so a raise there is a real defect and must
    # not be swallowed by the rescue above.
    it 'still raises at boot on an origin with no data-derived slot' do
      declare_query('menu')
      allow(Kiosk::Server::Queries).to receive(:catalog).and_raise('a real defect')

      expect { described_class.derive! }.to raise_error('a real defect')
    end
  end
end
