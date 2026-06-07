# frozen_string_literal: true

require "json"

RSpec.describe Kiosk::Server::WellKnown do
  before do
    Kiosk.configure do |c|
      c.issuer = "https://api.acme.example"
      c.owner  = { name: "Acme Inc.", support: "support@acme.example" }
    end
  end

  describe ".build" do
    subject(:doc) { described_class.build(base_url: "https://api.acme.example") }

    it "wraps everything under a top-level `kiosk` key" do
      expect(doc.keys).to eq([:kiosk])
    end

    it "advertises the document schema version" do
      expect(doc[:kiosk][:version]).to eq(described_class::DOCUMENT_VERSION)
    end

    it "computes the endpoint as base_url + mount_path" do
      expect(doc[:kiosk][:endpoint]).to eq("https://api.acme.example/kiosk")
    end

    it "respects an overridden mount_path" do
      Kiosk.configure { |c| c.mount_path = "/agent-surface" }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:endpoint]).to eq("https://api.acme.example/agent-surface")
    end

    it "strips trailing slashes from base_url" do
      d = described_class.build(base_url: "https://api.acme.example/")
      expect(d[:kiosk][:endpoint]).to eq("https://api.acme.example/kiosk")
    end

    it "advertises OAuth 2.1 endpoints under the same origin" do
      expect(doc[:kiosk][:auth][:kind]).to          eq("oauth2")
      expect(doc[:kiosk][:auth][:authorize_url]).to eq("https://api.acme.example/kiosk/oauth/authorize")
      expect(doc[:kiosk][:auth][:token_url]).to     eq("https://api.acme.example/kiosk/oauth/token")
    end

    it "passes through configured capabilities" do
      Kiosk.configure { |c| c.capabilities = %w[sql actions] }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:capabilities]).to eq(%w[sql actions])
    end

    it "passes through configured min_client" do
      Kiosk.configure { |c| c.min_client = "0.5.0" }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:min_client]).to eq("0.5.0")
    end

    it "advertises the configured issuer" do
      expect(doc[:kiosk][:issuer]).to eq("https://api.acme.example")
    end

    it "advertises the configured owner" do
      expect(doc[:kiosk][:owner][:name]).to    eq("Acme Inc.")
      expect(doc[:kiosk][:owner][:support]).to eq("support@acme.example")
    end

    it "raises if issuer is not configured" do
      Kiosk.reset!
      expect { described_class.build(base_url: "https://api.acme.example") }
        .to raise_error(ArgumentError, /issuer/)
    end

    it "raises if issuer is an empty string" do
      Kiosk.configure { |c| c.issuer = "" }
      expect { described_class.build(base_url: "https://api.acme.example") }
        .to raise_error(ArgumentError, /issuer/)
    end
  end

  describe ".build_json" do
    it "returns a parse-able JSON string" do
      json = described_class.build_json(base_url: "https://api.acme.example")
      parsed = JSON.parse(json)
      expect(parsed.dig("kiosk", "endpoint")).to eq("https://api.acme.example/kiosk")
    end
  end
end
