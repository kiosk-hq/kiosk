# frozen_string_literal: true

# THE `schema` CATALOG AND ITS BOOT DIGEST (T-094).
#
# The document `GET <endpoint>/schema` serves, derived once from the registry
# + the origin config + the gem version, and the digest that travels as its
# strong ETag and as the `?v=` cache-buster in every discovery link.
#
# What is proved here is the thing the whole design rests on: **the digest
# moves whenever the bytes a client would cache could move, and does not move
# otherwise.** A digest narrower than that is a stale catalogue with a green
# check beside it.

RSpec.describe Kiosk::Server::SchemaDocument do
  before do
    Kiosk.configure do |c|
      c.issuer = "https://demo.example"
    end
    described_class.reset!
  end

  after { described_class.reset! }

  def digest = described_class.digest

  describe ".document" do
    it "is exactly {queries, actions} — sorted descriptors, and NO `verbs`" do
      declare_query("menu", description: "Browse the menu")
      declare_action("place_order", description: "Place an order")

      document = described_class.document

      expect(document.keys).to eq(%i[queries actions])
      expect(document[:queries].map { |d| d[:name] }).to eq(%w[menu])
      expect(document[:actions].map { |d| d[:name] }).to eq(%w[place_order])
    end

    # T-095 / K-801. `verbs` rendered `Array(Kiosk.configuration.capabilities)`
    # — literally the call `/.well-known/kiosk.json` makes for `capabilities`,
    # so it was one value published twice, not two facts that agreed.
    it "does not republish the module set the discovery document owns" do
      declare_query("menu")

      expect(described_class.document).not_to have_key(:verbs)
      expect(described_class.json).not_to include("verbs")
      expect(Kiosk.configuration.capabilities).to include("schema")
    end

    it "answers an origin with nothing registered, rather than refusing" do
      expect(described_class.document).to eq(queries: [], actions: [])
    end
  end

  describe ".digest" do
    it "is 32 lowercase hex characters" do
      declare_query("menu")
      expect(digest).to match(/\A[0-9a-f]{32}\z/)
    end

    it "is STABLE across reads — the derivation happens once" do
      declare_query("menu")
      expect(digest).to eq(digest)
      expect(described_class.document).to equal(described_class.document)
    end

    # ── THE REGISTRY ────────────────────────────────────────────────────
    it "moves when a verb is ADDED" do
      declare_query("menu")
      before_add = digest

      declare_query("specials")
      expect(digest).not_to eq(before_add)
    end

    it "moves when a verb is REMOVED" do
      declare_query("menu")
      declare_query("specials")
      both = digest

      Kiosk::Server::Queries.unregister("specials")
      described_class.reset!
      expect(digest).not_to eq(both)
    end

    it "moves when only a DESCRIPTION changes" do
      declare_query("menu", description: "Generation 1.")
      first = digest

      Kiosk::Server::Queries.reset!
      described_class.reset!
      declare_query("menu", description: "Generation 2.")
      expect(digest).not_to eq(first)
    end

    # ── THE ORIGIN CONFIG ───────────────────────────────────────────────
    it "moves when the mount path moves" do
      declare_query("menu")
      before_move = digest

      Kiosk.configure { |c| c.mount_path = "/api/kiosk" }
      described_class.reset!
      expect(digest).not_to eq(before_move)
    end

    it "moves when the skill pin is re-issued" do
      declare_query("menu")
      unpinned = digest

      Kiosk.configure { |c| c.skill_url = "https://kiosk.tech/skill-v9.9.9.md" }
      described_class.reset!
      expect(digest).not_to eq(unpinned)
    end

    # ── THE GEM VERSION, which is the reason nothing is pre-generated ───
    #
    # Phil's own objection to emitting a file at deploy time, verbatim: «не
    # только изменение состава queries/actions может повлиять на файл, но и
    # обновление версии kiosk-server (patch, например)». A digest over the
    # registry alone would be unchanged across a PATCH bump that changed the
    # renderer — and every cache in the world would keep the old answer.
    it "moves when kiosk-server's own version moves, with the registry untouched" do
      declare_query("menu")
      at_current = digest

      described_class.reset!
      stub_const("Kiosk::Server::VERSION", "9.9.9")
      expect(digest).not_to eq(at_current)
    end
  end

  describe ".etag" do
    it "is the digest, quoted, and STRONG — no `W/` prefix" do
      declare_query("menu")
      expect(described_class.etag).to eq(%("#{digest}"))
      expect(described_class.etag).not_to start_with("W/")
    end
  end

  describe "the boot contract" do
    it "reports NOT derived before anything asks, and derived after derive!" do
      declare_query("menu")
      expect(described_class.derived?).to be(false)

      described_class.derive!
      expect(described_class.derived?).to be(true)
    end

    it "is dropped by reset! — the engine's to_prepare hook, for a dev reload" do
      declare_query("menu")
      described_class.derive!

      described_class.reset!
      expect(described_class.derived?).to be(false)
    end

    it "re-derives after a reset rather than serving the dropped memo" do
      declare_query("menu")
      first = digest

      Kiosk::Server::Queries.reset!
      described_class.reset!
      declare_query("brunch")

      expect(digest).not_to eq(first)
      expect(described_class.document[:queries].map { |d| d[:name] }).to eq(%w[brunch])
    end
  end

  # ── A DATA-DERIVED SLOT (K-922) ────────────────────────────────────────────
  #
  # Phil: «каталог должен обновляться динамически, без деплоя. Было бы глупо
  # деплоить … для того чтобы опубликовалось новое объявление.» A slot declared
  # `enum: -> { Category.pluck(:slug) }` makes the catalogue a function of the
  # operator's ROWS, and the boot memo is keyed on the verb NAMES — which do
  # not move when a category is added. Without the epoch in {cache_key} the
  # digest would freeze at boot and a new category would need a RESTART to be
  # published: the exact failure the decision rules out.
  describe "when a descriptor slot is data-derived" do
    it "moves the digest when the derived value changes, with no reset and no restart" do
      slugs = %w[bikes]
      Kiosk::Server::SchemaSlots.refresh_seconds = 0
      declare_query("board", input_schema: {
                      type: "object", properties: { category: { enum: -> { slugs } } },
                    })
      first = digest

      slugs = %w[bikes free] # the operator adds a category

      expect(digest).not_to eq(first)
      expect(described_class.json).to include('"enum":["bikes","free"]')
    end

    it "keeps the digest STABLE while the memo window holds" do
      slugs = %w[bikes]
      Kiosk::Server::SchemaSlots.refresh_seconds = 3600
      declare_query("board", input_schema: {
                      type: "object", properties: { category: { enum: -> { slugs } } },
                    })
      first = digest
      slugs = %w[bikes free]

      expect(digest).to eq(first)
    end

    # `after_initialize` runs on EVERY boot, `db:create` and `db:migrate`
    # included, and a proc that reads a table cannot succeed there. Eager
    # derivation is an optimisation, so it defers rather than taking the boot
    # down — and the failure is still visible, because `derived?` says so.
    it "defers derivation instead of failing the boot when the data is unreachable" do
      declare_query("board", input_schema: {
                      type: "object", properties: { category: { enum: -> { raise "no table yet" } } },
                    })

      expect { described_class.derive! }.not_to raise_error
      expect(described_class.derived?).to be(false)
    end

    # The other half of that: an origin with NO proc anywhere touches no
    # database during derivation, so a raise there is a real defect and must
    # not be swallowed by the rescue above.
    it "still raises at boot on an origin with no data-derived slot" do
      declare_query("menu")
      allow(Kiosk::Server::Queries).to receive(:catalog).and_raise("a real defect")

      expect { described_class.derive! }.to raise_error("a real defect")
    end
  end
end
