# frozen_string_literal: true

RSpec.describe Kiosk::Server::Actions do
  describe ".register + .fetch" do
    it "registers a block and fetches it back" do
      described_class.register("ping") { |args| { pong: args[:name] } }
      handler = described_class.fetch("ping")

      expect(handler.call(name: "world")).to eq(pong: "world")
    end

    it "registers an explicit callable" do
      callable = ->(args) { args[:x] * 2 }
      described_class.register("double", callable)

      expect(described_class.fetch("double").call(x: 3)).to eq(6)
    end

    it "accepts symbol names (stored as strings)" do
      described_class.register(:ping) { :ok }
      expect(described_class.fetch("ping")).to be_a(Proc)
      expect(described_class.fetch(:ping)).to  be_a(Proc)
    end

    it "raises ArgumentError without a block or callable" do
      expect { described_class.register("naked") }
        .to raise_error(ArgumentError, /callable or a block/)
    end
  end

  describe ".fetch unknown name" do
    it "raises NotFound whose hint names the available actions and points at the schema" do
      described_class.register("place_order") { :ok }
      described_class.register("cancel_order") { :ok }

      expect { described_class.fetch("order") }
        .to raise_error(Kiosk::Server::Errors::NotFound) { |e|
          expect(e.message).to include("order")
          # names an available action so a near-miss typo is recoverable...
          expect(e.hint).to include("place_order")
          expect(e.hint).to include("cancel_order")
          # ...WITHOUT first fetching the schema, but still points there.
          expect(e.hint).to match(/schema/)
          expect(e.hint).to include("unknown action 'order'")
        }
    end
  end

  describe ".known" do
    it "lists registered action names" do
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
      described_class.register("place_order", description: "Place an order", params: { items: "array" }) { {} }

      descriptor = described_class.describe("place_order")
      expect(descriptor[:name]).to        eq("place_order")
      expect(descriptor[:description]).to eq("Place an order")
      expect(descriptor[:params]).to      eq({ items: "array" })
    end

    it "fetch still returns the callable (not the Entry)" do
      handler = ->(args) { { ok: true } }
      described_class.register("go", handler, description: "Go action")

      fetched = described_class.fetch("go")
      expect(fetched).to eq(handler)
      expect(fetched.call({})).to eq({ ok: true })
    end

    it "register without metadata leaves description and params nil" do
      described_class.register("bare") { {} }

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
        required: ["items"],
        properties: { items: { type: "array", items: { type: "string" } } },
      }
    end

    it "register accepts input_schema:/example_params:/example_row: and exposes them via describe" do
      described_class.register("place_order",
        description: "Place an order",
        params: { items: "array" },
        input_schema: input_schema,
        example_params: { items: ["milk-1l"] },
        example_row: { order_id: "abc", status: "placed" }) { {} }

      d = described_class.describe("place_order")
      expect(d[:input_schema]).to   eq(input_schema)
      expect(d[:example_params]).to eq({ items: ["milk-1l"] })
      expect(d[:example_row]).to    eq({ order_id: "abc", status: "placed" })
    end

    # Back-compat: a descriptor with no extensions is byte-for-byte the old shape.
    it "OMITS the new keys entirely when they are not supplied (existing descriptors unchanged)" do
      described_class.register("plain", description: "Do", params: { x: "string" }) { {} }

      d = described_class.describe("plain")
      expect(d).to eq({ name: "plain", description: "Do", params: { x: "string" } })
      expect(d).not_to have_key(:input_schema)
      expect(d).not_to have_key(:example_params)
      expect(d).not_to have_key(:example_row)
    end
  end
end
