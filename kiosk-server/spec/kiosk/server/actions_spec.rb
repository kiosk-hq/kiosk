# frozen_string_literal: true

# The write-side registry, exercised the ONE way a verb gets into it (T-081):
# a controller that includes Kiosk::Handler and declares `kind :action`, with class-level macros claimed by
# the next `def`. `declare_action` (spec_helper) builds exactly that. See
# queries_spec.rb for the read side — the two registries are the same code.
RSpec.describe Kiosk::Server::Actions do
  describe ".fetch" do
    it "returns the registered handler" do
      declare_action("ping")

      expect(described_class.fetch("ping")).to be_a(Kiosk::Server::HandlerDispatch)
    end

    it "accepts a symbol name (registry keys are strings)" do
      declare_action("ping")

      expect(described_class.fetch(:ping)).to eq(described_class.fetch("ping"))
    end
  end

  describe ".fetch unknown name" do
    it "raises NotFound whose hint names the available actions and points at the schema" do
      declare_action("place_order")
      declare_action("cancel_order")

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
      declare_action("a")
      declare_action("b")
      expect(described_class.known).to contain_exactly("a", "b")
    end

    it "is empty after reset!" do
      declare_action("a")
      described_class.reset!
      expect(described_class.known).to be_empty
    end
  end

  describe ".describe" do
    it "carries the declared description into the descriptor" do
      declare_action("place_order", description: "Place an order")

      descriptor = described_class.describe("place_order")
      expect(descriptor[:name]).to        eq("place_order")
      expect(descriptor[:description]).to eq("Place an order")
    end

    # ADR-0023 retired the free-text `params` hint and the mixin has no macro
    # for it, so every descriptor this implementation publishes carries null.
    # The KEY stays on the wire — dropping it would be a wire change.
    it "always publishes params as nil — retired by ADR-0023, no macro declares it" do
      declare_action("place_order", description: "Place an order")

      expect(described_class.describe("place_order")).to have_key(:params)
      expect(described_class.describe("place_order")[:params]).to be_nil
    end

    it "leaves description nil when the verb opted in with another macro" do
      declare_action("bare", input_schema: { type: "object" })

      descriptor = described_class.describe("bare")
      expect(descriptor[:description]).to be_nil
      expect(descriptor[:params]).to      be_nil
    end

    it "fetch returns the handler, not the Entry" do
      declare_action("go", description: "Go action") { render json: { ok: true } }

      fetched = described_class.fetch("go")
      expect(fetched).not_to be_a(described_class::Entry)
      expect(fetched).to respond_to(:call)
    end
  end

  describe ".catalog" do
    it "returns all descriptors sorted by name" do
      declare_action("zebra", description: "Last")
      declare_action("apple", description: "First")

      cat = described_class.catalog
      expect(cat.map { |d| d[:name] }).to eq(%w[apple zebra])
      expect(cat.first[:description]).to  eq("First")
      expect(cat.last[:description]).to   eq("Last")
    end

    it "is empty after reset!" do
      declare_action("a")
      described_class.reset!
      expect(described_class.catalog).to be_empty
    end

    it "leaves known returning names only" do
      declare_action("x", description: "Something")
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

    it "carries the declared schemas and examples into the descriptor" do
      declare_action("place_order",
        description: "Place an order",
        input_schema: input_schema,
        example_params: { items: ["milk-1l"] },
        example_row: { order_id: "abc", status: "placed" })

      d = described_class.describe("place_order")
      expect(d[:input_schema]).to   eq(input_schema)
      expect(d[:example_params]).to eq({ items: ["milk-1l"] })
      expect(d[:example_row]).to    eq({ order_id: "abc", status: "placed" })
    end

    # Through `declare` rather than the mixin: T-073 = A makes both schemas
    # REQUIRED, so {HandlerMixin} raises on a declaration missing either and no
    # operator can produce one. The omission behaviour is this REGISTRY's, and
    # it still matters for `example_params`/`example_row`, which stay optional —
    # an absent extension is absent, never a null an assistant has to interpret.
    it "OMITS the extension keys entirely when they are not declared" do
      described_class.declare("plain", ->(_args) { {} }, description: "Do")

      d = described_class.describe("plain")
      expect(d).to eq({ name: "plain", description: "Do", params: nil })
      expect(d).not_to have_key(:input_schema)
      expect(d).not_to have_key(:output_schema)
      expect(d).not_to have_key(:example_params)
      expect(d).not_to have_key(:example_row)
    end
  end
end
