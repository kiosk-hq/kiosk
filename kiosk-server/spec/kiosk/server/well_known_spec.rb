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
      # Default skill URL is the immutable versioned artifact (ADR-0012).
      expect(d[:kiosk][:skill]).to eq(url: "https://kiosk.tech/skill-v0.1.2.md", sha256: "abc123")
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

  # ─── W1: agents.txt native discovery envelope ────────────────────────────
  describe ".agents_txt" do
    subject(:body) { described_class.agents_txt(base_url: "https://api.acme.example") }

    # Parse the non-comment, non-blank lines into a Key => value hash.
    def directives(text)
      text.each_line.filter_map do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, _, value = line.partition(":")
        [key.strip, value.strip]
      end.to_h
    end

    it "returns a String" do
      expect(body).to be_a(String)
    end

    it "carries the agents.txt v1.0 payment + auth directives" do
      d = directives(body)
      expect(d["Protocols"]).to eq("ap2")
      expect(d["Payments"]).to eq("required")
      expect(d["Authorization"]).to eq("agent-auth")
      expect(d["Identity"]).to eq("required")
    end

    it "emits a Skills directive pointing at the configured skill URL" do
      Kiosk.configure { |c| c.skill_url = "https://kiosk.tech/skill-v0.1.2.md" }
      d = directives(described_class.agents_txt(base_url: "https://api.acme.example"))
      expect(d["Skills"]).to eq("https://kiosk.tech/skill-v0.1.2.md")
    end

    it "has a `#` comment header and a JSON pointer comment" do
      expect(body).to match(/\A#/)
      expect(body).to include("# JSON: https://api.acme.example/agents.json")
    end

    it "every non-comment, non-blank line is a `Key: value` directive" do
      body.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        expect(line).to match(/\A[A-Za-z][\w-]*:\s?.+\z/)
      end
    end

    it "validates the issuer (same contract as build)" do
      Kiosk.reset!
      expect { described_class.agents_txt(base_url: "https://api.acme.example") }
        .to raise_error(ArgumentError, /issuer/)
    end
  end

  # ─── W1: agents.json native discovery companion ──────────────────────────
  describe ".agents_json" do
    subject(:doc) { described_class.agents_json(base_url: "https://api.acme.example") }

    it "carries the agents.json v1.0 required keys" do
      expect(doc[:version]).to eq("1.0")
      expect(doc[:standard]).to be_a(String)
      expect(doc[:site]).to include(:name, :url)
    end

    it "derives site.url from the base_url and site.name from the owner" do
      expect(doc[:site][:url]).to eq("https://api.acme.example")
      expect(doc[:site][:name]).to eq("Acme Inc.")
    end

    it "falls back to the issuer host for site.name when no owner name is set" do
      Kiosk.configure { |c| c.owner = {} }
      d = described_class.agents_json(base_url: "https://api.acme.example")
      expect(d[:site][:name]).to eq("api.acme.example")
    end

    it "declares AP2 payments as required" do
      expect(doc[:payments][:required]).to be(true)
      expect(doc[:payments]).to have_key(:ap2)
    end

    it "advertises agent-auth with the agent-configuration discovery pointer" do
      expect(doc[:authorization][:protocols]).to eq(["agent-auth"])
      expect(doc[:authorization][:discovery]).to eq("/.well-known/agent-configuration")
      expect(doc[:authorization][:identity]).to eq("required")
    end

    it "lists the configured skill" do
      Kiosk.configure { |c| c.skill_url = "https://kiosk.tech/skill-v0.1.2.md" }
      d = described_class.agents_json(base_url: "https://api.acme.example")
      expect(d[:skills].first[:url]).to eq("https://kiosk.tech/skill-v0.1.2.md")
    end

    it "carries the six-verb contract under the x-kiosk extension" do
      Kiosk::Server::Queries.register("catalog") { [] }
      d = described_class.agents_json(base_url: "https://api.acme.example")
      xk = d[:"x-kiosk"]
      expect(xk[:wire][:verbs]).to eq(Array(Kiosk.configuration.capabilities))
      expect(xk[:wire][:schema]).to eq("/kiosk/schema")
      expect(xk[:mount_path]).to eq("/kiosk")
      expect(xk[:api_version]).to eq(Kiosk::Protocol::API_VERSION)
      expect(xk[:min_client]).to eq(Kiosk.configuration.min_client)
    end

    it "round-trips through JSON" do
      json = described_class.agents_json_string(base_url: "https://api.acme.example")
      parsed = JSON.parse(json)
      expect(parsed["version"]).to eq("1.0")
      expect(parsed.dig("site", "url")).to eq("https://api.acme.example")
    end
  end

  # ─── W3: /.well-known/agent-configuration (agent-auth discovery) ─────────
  describe ".agent_configuration" do
    subject(:doc) { described_class.agent_configuration(base_url: "https://api.acme.example") }

    it "advertises the issuer" do
      expect(doc[:issuer]).to eq("https://api.acme.example")
    end

    it "lists the four auth endpoints as absolute URLs" do
      expect(doc[:endpoints][:challenge]).to eq("https://api.acme.example/kiosk/auth/challenge")
      expect(doc[:endpoints][:register]).to  eq("https://api.acme.example/kiosk/auth/register")
      expect(doc[:endpoints][:login]).to     eq("https://api.acme.example/kiosk/auth/login")
      expect(doc[:endpoints][:revoke]).to    eq("https://api.acme.example/kiosk/auth/revoke")
    end

    it "points at the JWKS document" do
      expect(doc[:jwks_uri]).to eq("https://api.acme.example/kiosk/.well-known/jwks.json")
    end

    it "declares the kiosk-pop auth mode" do
      expect(doc[:auth_modes]).to eq(["kiosk-pop"])
    end

    it "respects an overridden mount_path across all endpoints" do
      Kiosk.configure { |c| c.mount_path = "/agent-surface" }
      d = described_class.agent_configuration(base_url: "https://api.acme.example")
      expect(d[:endpoints][:challenge]).to eq("https://api.acme.example/agent-surface/auth/challenge")
      expect(d[:jwks_uri]).to eq("https://api.acme.example/agent-surface/.well-known/jwks.json")
    end

    it "validates the issuer (same contract as build)" do
      Kiosk.reset!
      expect { described_class.agent_configuration(base_url: "https://api.acme.example") }
        .to raise_error(ArgumentError, /issuer/)
    end
  end
end
