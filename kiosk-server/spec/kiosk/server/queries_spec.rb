# frozen_string_literal: true

RSpec.describe Kiosk::Server::Queries do
  describe ".register + .fetch" do
    it "registers a block and fetches it back" do
      described_class.register("menu") { |params| [{ id: 1, name: "Margherita" }] }
      handler = described_class.fetch("menu")

      expect(handler.call({})).to eq([{ id: 1, name: "Margherita" }])
    end

    it "registers an explicit callable" do
      callable = ->(params) { [{ result: params[:x] * 2 }] }
      described_class.register("double", callable)

      expect(described_class.fetch("double").call(x: 3)).to eq([{ result: 6 }])
    end

    it "accepts symbol names (stored as strings)" do
      described_class.register(:menu) { [] }
      expect(described_class.fetch("menu")).to be_a(Proc)
      expect(described_class.fetch(:menu)).to  be_a(Proc)
    end

    it "raises ArgumentError without a block or callable" do
      expect { described_class.register("naked") }
        .to raise_error(ArgumentError, /callable or a block/)
    end
  end

  describe ".fetch unknown name" do
    it "raises NotFound whose hint names the available queries and points at the schema" do
      described_class.register("browse_listings") { [] }
      described_class.register("listing_detail") { [] }

      expect { described_class.fetch("listings") }
        .to raise_error(Kiosk::Server::Errors::NotFound) { |e|
          expect(e.message).to include("listings")
          # names an available query so a near-miss typo is recoverable...
          expect(e.hint).to include("browse_listings")
          expect(e.hint).to include("listing_detail")
          # ...WITHOUT first fetching the schema, but still points there.
          expect(e.hint).to match(/schema/)
          expect(e.hint).to include("unknown query 'listings'")
        }
    end

    it "caps a very long hint list at 20 names + an ellipsis, still pointing at the schema" do
      30.times { |i| described_class.register(format("q%02d", i)) { [] } }

      expect { described_class.fetch("nope") }
        .to raise_error(Kiosk::Server::Errors::NotFound) { |e|
          expect(e.hint).to include("q00")
          expect(e.hint).to include("q19")
          expect(e.hint).not_to include("q20") # capped
          expect(e.hint).to include("…")
          expect(e.hint).to match(/schema/)
        }
    end
  end

  describe ".known" do
    it "lists registered query names" do
      described_class.register("a") { }
      described_class.register("b") { }
      expect(described_class.known).to contain_exactly("a", "b")
    end

    it "is empty after reset!" do
      described_class.register("a") { }
      described_class.reset!
      expect(described_class.known).to be_empty
    end
  end

  describe "metadata (description: / params:)" do
    it "register with description: and params: exposes them via describe" do
      described_class.register("menu", description: "Browse the menu", params: { restaurant_id: "string" }) { [] }

      descriptor = described_class.describe("menu")
      expect(descriptor[:name]).to        eq("menu")
      expect(descriptor[:description]).to eq("Browse the menu")
      expect(descriptor[:params]).to      eq({ restaurant_id: "string" })
    end

    it "fetch still returns the callable (not the Entry)" do
      handler = ->(p) { [{ id: 1 }] }
      described_class.register("items", handler, description: "List items")

      fetched = described_class.fetch("items")
      expect(fetched).to eq(handler)
      expect(fetched.call({})).to eq([{ id: 1 }])
    end

    it "register without metadata leaves description and params nil" do
      described_class.register("bare") { [] }

      descriptor = described_class.describe("bare")
      expect(descriptor[:description]).to be_nil
      expect(descriptor[:params]).to      be_nil
    end

    it "catalog returns all descriptors sorted by name" do
      described_class.register("zebra", description: "Last") { }
      described_class.register("apple", description: "First") { }

      cat = described_class.catalog
      expect(cat.map { |d| d[:name] }).to eq(%w[apple zebra])
      expect(cat.first[:description]).to  eq("First")
      expect(cat.last[:description]).to   eq("Last")
    end

    it "catalog is empty after reset!" do
      described_class.register("a") { }
      described_class.reset!
      expect(described_class.catalog).to be_empty
    end

    it "known is unchanged (still returns names only)" do
      described_class.register("x", description: "Something") { }
      expect(described_class.known).to eq(["x"])
    end
  end

  describe "machine-readable descriptor extensions (input_schema / example_params / example_row — ADR-0021)" do
    let(:input_schema) do
      {
        type: "object",
        required: ["city"],
        properties: {
          city:  { type: "string" },
          limit: { type: "integer", minimum: 1, maximum: 50 },
        },
      }
    end

    it "register accepts input_schema:/example_params:/example_row: and exposes them via describe" do
      described_class.register("search",
        description: "Search hotels",
        params: { city: "string" },
        input_schema: input_schema,
        example_params: { city: "Lisbon", limit: 20 },
        example_row: { id: 7, name: "Grand Aljube", city: "Lisbon" }) { [] }

      d = described_class.describe("search")
      expect(d[:input_schema]).to   eq(input_schema)
      expect(d[:example_params]).to eq({ city: "Lisbon", limit: 20 })
      expect(d[:example_row]).to    eq({ id: 7, name: "Grand Aljube", city: "Lisbon" })
    end

    # Back-compat: a descriptor with no extensions is byte-for-byte the old shape.
    it "OMITS the new keys entirely when they are not supplied (existing descriptors unchanged)" do
      described_class.register("plain", description: "Browse", params: { x: "string" }) { [] }

      d = described_class.describe("plain")
      expect(d).to eq({ name: "plain", description: "Browse", params: { x: "string" } })
      expect(d).not_to have_key(:input_schema)
      expect(d).not_to have_key(:example_params)
      expect(d).not_to have_key(:example_row)
    end

    it "emits only the extension keys that were supplied" do
      described_class.register("partial", example_params: { city: "Porto" }) { [] }

      d = described_class.describe("partial")
      expect(d).to have_key(:example_params)
      expect(d).not_to have_key(:input_schema)
      expect(d).not_to have_key(:example_row)
    end
  end
end
