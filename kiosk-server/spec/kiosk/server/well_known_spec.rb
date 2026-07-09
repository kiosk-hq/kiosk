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

    it "advertises the proof-of-possession auth surface under the same origin" do
      expect(doc[:kiosk][:auth][:kind]).to          eq("kiosk-pop")
      expect(doc[:kiosk][:auth][:challenge_url]).to eq("https://api.acme.example/kiosk/auth/challenge")
      expect(doc[:kiosk][:auth][:register_url]).to  eq("https://api.acme.example/kiosk/auth/register")
      expect(doc[:kiosk][:auth][:login_url]).to     eq("https://api.acme.example/kiosk/auth/login")
      expect(doc[:kiosk][:auth][:revoke_url]).to    eq("https://api.acme.example/kiosk/auth/revoke")
    end

    it "does not advertise a legacy OAuth surface" do
      expect(doc[:kiosk][:auth]).not_to have_key(:authorize_url)
      expect(doc[:kiosk][:auth]).not_to have_key(:token_url)
    end

    # capabilities is computed from the live registry (ADR-0009): empty here
    # since this context registers no queries/actions and wires no payment.
    it "advertises an empty capability set when nothing is registered" do
      expect(doc[:kiosk][:capabilities]).to eq([])
    end

    it "advertises the computed verb names (schema/query/run/pay) from the registry" do
      Kiosk::Server::Queries.register("catalog") { [] }
      Kiosk::Server::Actions.register("checkout") { {} }
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:capabilities]).to eq(%w[schema query run pay])
    end

    it "passes through an explicitly pinned capability list" do
      Kiosk::Server::Queries.register("catalog") { [] }
      Kiosk.configure { |c| c.capabilities = %w[schema query] }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:capabilities]).to eq(%w[schema query])
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

    it "omits the skill block when skill_sha256 is not set" do
      expect(doc[:kiosk]).not_to have_key(:skill)
    end

    it "advertises the skill descriptor when skill_sha256 is set" do
      Kiosk.configure { |c| c.skill_sha256 = "abc123" }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:skill]).to eq(url: "https://kiosk.tech/skill-v1.0.md", sha256: "abc123")
    end

    it "respects an overridden skill_url" do
      Kiosk.configure do |c|
        c.skill_url    = "https://kiosk.tech/skill-v1.1.md"
        c.skill_sha256 = "def456"
      end
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:skill]).to eq(url: "https://kiosk.tech/skill-v1.1.md", sha256: "def456")
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
