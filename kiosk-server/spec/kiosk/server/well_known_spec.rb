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

    it "advertises the account-binding endpoints (additive keys, ADR-0017)" do
      expect(doc[:kiosk][:auth][:device_authorization_url])
        .to eq("https://api.acme.example/kiosk/oauth/device_authorization")
      expect(doc[:kiosk][:auth][:claim_url])
        .to eq("https://api.acme.example/kiosk/auth/claim")
    end

    it "keeps the pre-binding auth keys first and byte-identical (additive-only rule)" do
      expect(doc[:kiosk][:auth].keys.first(5))
        .to eq(%i[kind challenge_url register_url login_url revoke_url])
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
      expect(d[:kiosk][:skill]).to eq(url: "https://kiosk.tech/skill-v0.2.0.md", sha256: "abc123")
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

    it "carries the agents.txt v1.0 payment + auth directives (auth-md alongside agent-auth)" do
      d = directives(body)
      expect(d["Protocols"]).to eq("ap2")
      expect(d["Payments"]).to eq("required")
      expect(d["Authorization"]).to eq("agent-auth auth-md")
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

    it "advertises agent-auth + auth-md with the agent-configuration discovery pointer" do
      expect(doc[:authorization][:protocols]).to eq(["agent-auth", "auth-md"])
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

    it "points at the RFC 9727 api-catalog under the x-kiosk extension" do
      expect(doc[:"x-kiosk"][:api_catalog]).to eq("/.well-known/api-catalog")
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

    it "declares kiosk-pop plus the binding modes (ADR-0017)" do
      expect(doc[:auth_modes]).to eq(["kiosk-pop", "user-claimed", "link-code"])
    end

    it "points at /auth.md for the full method description" do
      expect(doc[:auth_md]).to eq("https://api.acme.example/auth.md")
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

  # ─── W5: /auth.md (auth.md-vocabulary method description) ────────────────
  describe ".auth_md" do
    subject(:body) { described_class.auth_md(base_url: "https://api.acme.example") }

    it "follows the canonical auth.md section order" do
      sections = body.each_line.filter_map { |l| l.chomp[/\A## (.+)\z/, 1]&.strip }
      expect(sections).to eq([
        "Discover", "Pick a method", "Register", "Claim ceremony",
        "Exchange", "Use the access_token", "Errors", "Revocation",
      ])
      expect(body).to start_with("# ")
    end

    it "presents kiosk-pop as anonymous-class + PoP upgrade — NEVER as Agent Verified" do
      expect(body).to match(/anonymous/i)
      expect(body).to match(/proof-of-possession/i)
      expect(body).not_to include("Agent Verified")
    end

    it "marks identity assertion (ID-JAG) as not supported / planned" do
      expect(body).to match(/Identity assertion \(ID-JAG\).*not supported \(planned\)/)
    end

    it "labels the link flow a Kiosk extension (auth.md has no human-initiated direction)" do
      expect(body).to match(/Link code.*Kiosk extension/m)
    end

    it "advertises the ceremony endpoints as absolute URLs under the mount" do
      expect(body).to include("https://api.acme.example/kiosk/oauth/device_authorization")
      expect(body).to include("https://api.acme.example/kiosk/auth/claim")
      expect(body).to include("https://api.acme.example/kiosk/auth/login")
      expect(body).to include("https://api.acme.example/kiosk/auth/unlink")
    end

    it "documents the OAuth error vocabulary as the envelope exception" do
      %w[authorization_pending slow_down expired_token access_denied
         invalid_grant invalid_client].each do |code|
        expect(body).to include(code)
      end
    end

    it "requires the possession proof in the token poll (BIND-POP is not optional)" do
      expect(body).to match(/`signed`.*possession proof/m)
      expect(body).to include("No binding happens without a valid possession proof")
    end

    it "states the reputation-carry rule (claiming never whitewashes)" do
      expect(body).to match(/reputation\s+carries over/)
    end

    it "validates the issuer (same contract as build)" do
      Kiosk.reset!
      expect { described_class.auth_md(base_url: "https://api.acme.example") }
        .to raise_error(ArgumentError, /issuer/)
    end
  end

  # ─── W-catalog: /.well-known/api-catalog (RFC 9727 linkset) ──────────────
  describe ".api_catalog" do
    subject(:doc) { described_class.api_catalog(base_url: "https://api.acme.example") }

    # The linkset's single member: anchored at the api-catalog URL, carrying
    # the `item` link array.
    def member(d) = d[:linkset].first

    it "returns an RFC 9727 linkset anchored at the api-catalog URL" do
      expect(doc).to have_key(:linkset)
      expect(member(doc)[:anchor]).to eq("https://api.acme.example/.well-known/api-catalog")
    end

    it "carries a non-empty item array of endpoint links" do
      items = member(doc)[:item]
      expect(items).to be_an(Array)
      expect(items).not_to be_empty
      expect(items).to all(include(:href, :rel))
    end

    it "links the wire endpoints present in capabilities" do
      Kiosk::Server::Queries.register("catalog") { [] }
      Kiosk::Server::Actions.register("checkout") { {} }
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      hrefs = member(d)[:item].map { |i| i[:href] }
      expect(hrefs).to include("https://api.acme.example/kiosk/schema")
      expect(hrefs).to include("https://api.acme.example/kiosk/query")
      expect(hrefs).to include("https://api.acme.example/kiosk/run")
      expect(hrefs).to include("https://api.acme.example/kiosk/pay")
    end

    it "omits wire endpoints not present in capabilities" do
      # Register only a query → capabilities = [schema, query]; run/pay absent.
      Kiosk::Server::Queries.register("catalog") { [] }
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      hrefs = member(d)[:item].map { |i| i[:href] }
      expect(hrefs).to include("https://api.acme.example/kiosk/schema")
      expect(hrefs).to include("https://api.acme.example/kiosk/query")
      expect(hrefs).not_to include("https://api.acme.example/kiosk/run")
      expect(hrefs).not_to include("https://api.acme.example/kiosk/pay")
    end

    it "links no wire endpoints when nothing is registered (schema absent)" do
      # Bare config registers no queries/actions → capabilities = []; only the
      # agents.json discovery companion is catalogued.
      hrefs = member(doc)[:item].map { |i| i[:href] }
      expect(hrefs).to eq(["https://api.acme.example/agents.json"])
    end

    it "tags the schema endpoint as the machine-readable service-desc" do
      Kiosk::Server::Queries.register("catalog") { [] }
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      schema = member(d)[:item].find { |i| i[:href].end_with?("/schema") }
      expect(schema[:rel]).to eq("service-desc")
    end

    it "tags the non-schema wire endpoints with rel=item" do
      Kiosk::Server::Actions.register("checkout") { {} }
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      run = d[:linkset].first[:item].find { |i| i[:href].end_with?("/run") }
      expect(run[:rel]).to eq("item")
    end

    it "links the agents.json discovery companion" do
      hrefs = member(doc)[:item].map { |i| i[:href] }
      expect(hrefs).to include("https://api.acme.example/agents.json")
    end

    it "respects an overridden mount_path for the wire endpoints" do
      Kiosk::Server::Queries.register("catalog") { [] }
      Kiosk.configure { |c| c.mount_path = "/agent-surface" }
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      hrefs = d[:linkset].first[:item].map { |i| i[:href] }
      expect(hrefs).to include("https://api.acme.example/agent-surface/schema")
    end

    it "strips trailing slashes from base_url" do
      d = described_class.api_catalog(base_url: "https://api.acme.example/")
      expect(d[:linkset].first[:anchor])
        .to eq("https://api.acme.example/.well-known/api-catalog")
    end

    it "validates the issuer (same contract as build)" do
      Kiosk.reset!
      expect { described_class.api_catalog(base_url: "https://api.acme.example") }
        .to raise_error(ArgumentError, /issuer/)
    end

    describe ".api_catalog_string" do
      it "round-trips through JSON" do
        json = described_class.api_catalog_string(base_url: "https://api.acme.example")
        parsed = JSON.parse(json)
        expect(parsed.dig("linkset", 0, "anchor"))
          .to eq("https://api.acme.example/.well-known/api-catalog")
      end
    end
  end
end
