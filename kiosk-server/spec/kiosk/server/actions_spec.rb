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
end
