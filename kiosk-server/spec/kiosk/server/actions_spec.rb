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
    it "raises NotFound with a helpful hint listing known actions" do
      described_class.register("ping") { :ok }
      described_class.register("pong") { :ok }

      expect { described_class.fetch("nope") }
        .to raise_error(Kiosk::Server::Errors::NotFound) { |e|
          expect(e.message).to include("nope")
          expect(e.hint).to    include("ping")
          expect(e.hint).to    include("pong")
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
end
