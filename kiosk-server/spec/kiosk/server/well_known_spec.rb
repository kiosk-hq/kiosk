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

    it "advertises the account-binding endpoints (additive keys)" do
      expect(doc[:kiosk][:auth][:device_authorization_url])
        .to eq("https://api.acme.example/kiosk/oauth/device_authorization")
      expect(doc[:kiosk][:auth][:claim_url])
        .to eq("https://api.acme.example/kiosk/auth/claim")
    end

    it "keeps the pre-binding auth keys first and byte-identical (additive-only rule)" do
      expect(doc[:kiosk][:auth].keys.first(5))
        .to eq(%i[kind challenge_url register_url login_url revoke_url])
    end

    # capabilities is computed from the live registry: empty here
    # since this context registers no queries/actions and wires no payment.
    it "advertises an empty capability set when nothing is registered" do
      expect(doc[:kiosk][:capabilities]).to eq([])
    end

    it "advertises the computed module names (schema/queries/actions/pay)" do
      declare_query("catalog")
      declare_action("checkout")
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:capabilities]).to eq(%w[schema queries actions pay])
    end

    # STILL TRUE, FOR A DIFFERENT REASON (T-093, 2026-08-19). It was a
    # SECURITY property — the verb names stayed behind the Bearer gate on
    # `GET <endpoint>/schema`. That gate is gone and the api-catalog now
    # hyperlinks every verb, so nothing is being withheld here. What holds the
    # rule up is T-075 = A: `kiosk.json` is a POINTER, not a copy of the
    # contract. An assistant reads the module set here and the names from the
    # catalog, and there is exactly one place each of those is published.
    it "never names a registered verb in this document — pointer, not copy" do
      declare_query("secret_pricing_tiers")
      declare_action("cancel_enterprise_contract")
      d = described_class.build(base_url: "https://api.acme.example")
      expect(JSON.generate(d)).not_to include("secret_pricing_tiers")
      expect(JSON.generate(d)).not_to include("cancel_enterprise_contract")
    end

    # ── THE CACHE-BUSTED CATALOG LINK (T-094) ────────────────────────────
    #
    # This document is the SHORT-lived half of the asset-pipeline pair: it
    # expires in minutes and republishes the link, which is what lets
    # `/kiosk/schema?v=<digest>` be cached for a year. Without the digest in
    # the URL a week-long TTL on a FIXED path means a CDN serving a catalogue
    # from before the last deploy — invisibly, to an assistant that then calls
    # verbs which no longer exist.
    it "links the catalog at its digest-versioned, immutable URL" do
      declare_query("catalog")
      d = described_class.build(base_url: "https://api.acme.example")
      digest = Kiosk::Server::SchemaDocument.digest

      expect(d[:kiosk][:schema_url])
        .to eq("https://api.acme.example/kiosk/schema?v=#{digest}")
      expect(digest).to match(/\A[0-9a-f]{32}\z/)
    end

    it "moves that link when the catalog moves — that is the whole mechanism" do
      declare_query("catalog")
      before_add = described_class.build(base_url: "https://api.acme.example")[:kiosk][:schema_url]

      declare_action("checkout")
      after_add = described_class.build(base_url: "https://api.acme.example")[:kiosk][:schema_url]

      expect(after_add).not_to eq(before_add)
    end

    it "passes through an explicitly pinned capability list" do
      declare_query("catalog")
      Kiosk.configure { |c| c.capabilities = %w[schema queries] }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:capabilities]).to eq(%w[schema queries])
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

    # The default URL literal lives in exactly ONE place — kiosk-server's own
    # `@skill_url ||=` in configuration_extension.rb (K-750). Restating it here
    # made a second copy that had to be hand-chased on every skill cut, and it
    # went red exactly that way; nothing guarded it, because the pin guard
    # reads initializers, not specs. What this example is actually about is the
    # WIRING — the discovery document advertises the configured default,
    # whatever it currently is — plus the one property that makes a pin
    # verifiable at all: the default names an IMMUTABLE versioned cut, never
    # the mutable `skill.md` alias, whose bytes change under a pin.
    #
    # Which version that is belongs to the two guards that can see it:
    # bin/check-version-parity holds it against the protocol's MAJOR.MINOR,
    # and kiosk-test-support's skill_pin_spec holds it against the bytes
    # kiosk.tech actually publishes.
    it "advertises the skill descriptor when skill_sha256 is set" do
      Kiosk.configure { |c| c.skill_sha256 = "abc123" }
      d = described_class.build(base_url: "https://api.acme.example")
      expect(d[:kiosk][:skill]).to eq(url: Kiosk.configuration.skill_url, sha256: "abc123")
      expect(Kiosk.configuration.skill_url)
        .to match(%r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z})
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

    it "carries the agents.txt v1.0 auth directives (auth-md alongside agent-auth)" do
      d = directives(body)
      expect(d["Authorization"]).to eq("agent-auth auth-md")
      expect(d["Identity"]).to eq("required")
    end

    # Payment directives are pay-conditional: emitted only when the
    # provider serves `pay` (a payment_provider is configured → `pay` is in the
    # computed capabilities).
    context "when the provider serves pay (payment_provider configured)" do
      before { Kiosk.configure { |c| c.payment_provider = Object.new } }

      it "carries the AP2 payment directives" do
        d = directives(described_class.agents_txt(base_url: "https://api.acme.example"))
        expect(d["Protocols"]).to eq("ap2")
        expect(d["Payments"]).to eq("required")
      end
    end

    context "when the provider serves no pay (no payment_provider)" do
      it "omits the AP2 payment directives but keeps auth/identity" do
        # Bare config from the outer `before` registers no payment_provider →
        # capabilities excludes `pay`.
        expect(body).not_to include("Protocols: ap2")
        expect(body).not_to include("Payments: required")
        d = directives(body)
        expect(d["Authorization"]).to eq("agent-auth auth-md")
        expect(d["Identity"]).to eq("required")
      end
    end

    it "emits a Skills directive pointing at the configured skill URL" do
      # Deliberately synthetic (not a published kiosk.tech artifact): this is a
      # round-trip on whatever skill_url is configured, and a synthetic value
      # cannot go stale — and cannot be mistaken for the shipped default, which
      # is asserted separately above (K-641).
      Kiosk.configure { |c| c.skill_url = "https://example.test/skill.md" }
      d = directives(described_class.agents_txt(base_url: "https://api.acme.example"))
      expect(d["Skills"]).to eq("https://example.test/skill.md")
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

    # The `payments` block is pay-conditional: present only when the
    # provider serves `pay` (payment_provider configured → `pay` in capabilities).
    # Optional in agents.json v1.0, so omitted otherwise.
    context "when the provider serves pay (payment_provider configured)" do
      before { Kiosk.configure { |c| c.payment_provider = Object.new } }

      it "declares AP2 payments as required" do
        d = described_class.agents_json(base_url: "https://api.acme.example")
        expect(d[:payments][:required]).to be(true)
        expect(d[:payments]).to have_key(:ap2)
      end
    end

    context "when the provider serves no pay (no payment_provider)" do
      it "omits the payments key entirely" do
        # Bare config from the outer `before` registers no payment_provider →
        # capabilities excludes `pay`.
        expect(doc).not_to have_key(:payments)
      end
    end

    it "advertises agent-auth + auth-md with the agent-configuration discovery pointer" do
      expect(doc[:authorization][:protocols]).to eq(["agent-auth", "auth-md"])
      expect(doc[:authorization][:discovery]).to eq("/.well-known/agent-configuration")
      expect(doc[:authorization][:identity]).to eq("required")
    end

    it "lists the configured skill" do
      # Synthetic on purpose — round-trip of the configured value, immune to
      # published-skill version bumps (K-641). The shipped default is pinned
      # and asserted in the skill-descriptor example above.
      Kiosk.configure { |c| c.skill_url = "https://example.test/skill.md" }
      d = described_class.agents_json(base_url: "https://api.acme.example")
      expect(d[:skills].first[:url]).to eq("https://example.test/skill.md")
    end

    # T-075 = A / ADR-0025: the block carries POINTERS, not a copy of the
    # contract. Four keys, exactly.
    it "carries the wire pointers under the x-kiosk extension" do
      declare_query("catalog")
      d = described_class.agents_json(base_url: "https://api.acme.example")
      xk = d[:"x-kiosk"]
      expect(xk.keys).to eq(%i[schema api_catalog mount_path api_version])
      # The pointer carries the same `?v=<digest>` cache-buster `kiosk.json`
      # publishes (T-094): a pointer a client may follow must point at the URL
      # that is safe to cache.
      expect(xk[:schema]).to eq("/kiosk/schema?v=#{Kiosk::Server::SchemaDocument.digest}")
      expect(xk[:api_catalog]).to eq("/.well-known/api-catalog")
      expect(xk[:mount_path]).to eq("/kiosk")
      expect(xk[:api_version]).to eq(Kiosk::Protocol::API_VERSION)
    end

    # It stopped echoing `capabilities` (the `wire.verbs` key is GONE): a
    # discovery envelope that restates the catalog is a second source of truth
    # for it, and `kiosk.json` is canonical. `min_client` went the same way.
    it "does not echo capabilities or min_client under x-kiosk" do
      declare_query("catalog")
      d = described_class.agents_json(base_url: "https://api.acme.example")
      xk = d[:"x-kiosk"]
      expect(xk).not_to have_key(:wire)
      expect(xk).not_to have_key(:verbs)
      expect(xk).not_to have_key(:capabilities)
      expect(xk).not_to have_key(:min_client)
    end

    # Same rule, same NEW reason as kiosk.json above: a pointer, not a copy.
    it "never names a registered verb in this companion — pointer, not copy" do
      declare_query("secret_pricing_tiers")
      d = described_class.agents_json(base_url: "https://api.acme.example")
      expect(JSON.generate(d)).not_to include("secret_pricing_tiers")
    end

    it "points at the RFC 9727 api-catalog under the x-kiosk extension" do
      expect(doc[:"x-kiosk"][:api_catalog]).to eq("/.well-known/api-catalog")
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

    it "declares kiosk-pop plus the binding modes" do
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

    # ── K-675: the register step must teach the ADR-0022 PoW transport ──────
    #
    # This is not a doc nit. The server reads registration proofs ONLY from
    # the `Kiosk-PoW` request header ({AuthController#register} →
    # {PowGate.proofs_from_header}); a `pow` key in the register BODY is
    # silently ignored. Every pow demo tolls registration unconditionally, so
    # an assistant that follows a body-pow auth.md 402-loops forever on the
    # very first call it makes. These two examples pin the served bytes.
    describe "the Register step (PoW transport)" do
      subject(:register) { body[/^## Register$.*?(?=^## )/m] }

      it "renders the register body as `{ public_key, signed }` — no body `pow`" do
        expect(register).to include("`{ public_key, signed }`")
        # No JSON-ish body example anywhere in the file may pair `signed`
        # with a `pow` field — that is the retired pre-ADR-0022 wire.
        expect(body).not_to match(/\{[^}]*\bsigned\b[^}]*\bpow\b/)
      end

      it "sends the proof in the `Kiosk-PoW` request header, never the body" do
        expect(register).to match(/`Kiosk-PoW`\s+request header/i)
        expect(register).to include("Kiosk-PoW: {")
        expect(register).to match(/NEVER travels in the\s+request body/)
        # The RFC 7235 pair: the 402 names the scheme, the client answers in
        # the matching request header.
        expect(register).to include("402 pow_required")
        expect(register).to include(%(WWW-Authenticate: Kiosk-PoW realm="<issuer>"))
      end
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

    it "maps only the modules that still HAVE a single endpoint" do
      # `queries` and `actions` LEFT this table at the 0.4 cutover, with the
      # two multiplexed endpoints they named (T-074 = A), and they do not come
      # back: a module holding N verbs has N endpoints, so the catalog links
      # THE VERBS (below) rather than inventing a module URL that answers
      # nothing.
      expect(described_class::MODULE_ENDPOINTS).to eq("pay" => "pay")
    end

    it "links the two descriptions, THEN every registered verb, then pay" do
      declare_query("catalog")
      declare_action("checkout")
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      hrefs = member(d)[:item].map { |i| i[:href] }
      # Every module is live here — schema, queries, actions AND pay. The two
      # `service-desc` members are UNCHANGED by T-093 (the strict RFC 9727
      # reading survives); what is new is one `item` per registered verb,
      # ALONGSIDE them, at the real 0.4 endpoint the verb answers on.
      expect(hrefs).to eq(["https://api.acme.example/kiosk/schema",
                           "https://api.acme.example/kiosk/openapi.json",
                           "https://api.acme.example/kiosk/catalog",
                           "https://api.acme.example/kiosk/checkout",
                           "https://api.acme.example/kiosk/pay",
                           "https://api.acme.example/agents.json"])
      expect(hrefs).not_to include("https://api.acme.example/kiosk/query")
      expect(hrefs).not_to include("https://api.acme.example/kiosk/run")
    end

    it "omits the endpoints of modules not present in capabilities" do
      # Register only a query → capabilities = [schema, queries]; the pay
      # module is absent, so its endpoint is not catalogued.
      declare_query("catalog")
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      hrefs = member(d)[:item].map { |i| i[:href] }
      expect(hrefs).to include("https://api.acme.example/kiosk/schema")
      expect(hrefs).not_to include("https://api.acme.example/kiosk/pay")
    end

    # ── K-799 = (b), T-093: THE INVERSE OF WHAT THIS FILE ASSERTED ───────
    #
    # This example is the same two fixture verbs as before — deliberately
    # named to sound like secrets — with the expectation turned around. Until
    # 2026-08-19 the catalog was required NOT to contain them, because it is
    # unauthenticated and the catalogue was behind a Bearer token. Phil
    # answered the premise: «на статичных GET endpoint'ах — пожалуйста…
    # Пускай долбятся в них сколько хотят без аутентификации». The names are
    # not secret, and this document is a render of in-process state, so it
    # caches behind a CDN and anonymous enumeration costs the origin nothing.
    #
    # It is written as the POSITIVE assertion rather than as the removal of a
    # negative one: "does not refuse to publish" is a green nothing, and this
    # has to fail if the widening is ever quietly reverted.
    it "hyperlinks EVERY registered verb, at its own endpoint, unauthenticated" do
      declare_query("secret_pricing_tiers")
      declare_action("cancel_enterprise_contract")
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      items = member(d)[:item]

      expect(items).to include(
        { href: "https://api.acme.example/kiosk/secret_pricing_tiers",
          rel: "item", "kiosk-method": ["GET"] },
        { href: "https://api.acme.example/kiosk/cancel_enterprise_contract",
          rel: "item", "kiosk-method": ["POST"] },
      )
    end

    # The METHOD is the half a bare href cannot carry, and it is not decorative:
    # a GET at an action's path is a 405. `kiosk-method` is an EXTENSION target
    # attribute, so RFC 9264 §4.2.4.3 serializes it as an array of strings.
    it "says which METHOD reaches each verb — GET a query, POST an action" do
      declare_query("catalog")
      declare_action("checkout")
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      by_href = member(d)[:item].to_h { |i| [i[:href], i[:"kiosk-method"]] }

      expect(by_href["https://api.acme.example/kiosk/catalog"]).to eq(["GET"])
      expect(by_href["https://api.acme.example/kiosk/checkout"]).to eq(["POST"])
      # A service description is not an operation and carries no method.
      expect(by_href["https://api.acme.example/kiosk/schema"]).to be_nil
    end

    # The RFC question T-093 re-settled: Phil overruled the SECURITY objection,
    # not slice 5's reading of RFC 9727 (a catalog lists APIs and points at
    # their DESCRIPTIONS). So both members survive, unchanged, and the
    # operations were ADDED alongside them rather than replacing them.
    it "keeps both service-desc members — the operations are added, not swapped in" do
      declare_query("catalog")
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      descs = member(d)[:item].select { |i| i[:rel] == "service-desc" }.map { |i| i[:href] }
      expect(descs).to eq(["https://api.acme.example/kiosk/schema",
                           "https://api.acme.example/kiosk/openapi.json"])
    end

    # THE CONDITION ON THE K-799 ANSWER, which is a condition and not a
    # footnote: it covers documents that are CHEAP AND STATIC to compose.
    # Widening the loop is only in scope while every member comes from
    # in-process state.
    it "composes from the registry alone — no per-request work to widen it" do
      declare_query("catalog")
      declare_action("checkout")

      expect(Kiosk::Server::Queries).to receive(:known).at_least(:once).and_call_original
      expect(Kiosk::Server::Actions).to receive(:known).at_least(:once).and_call_original
      described_class.api_catalog(base_url: "https://api.acme.example")
    end

    it "links no wire endpoints when nothing is registered (schema module absent)" do
      # Bare config registers no queries/actions → capabilities = []; only the
      # agents.json discovery companion is catalogued.
      hrefs = member(doc)[:item].map { |i| i[:href] }
      expect(hrefs).to eq(["https://api.acme.example/agents.json"])
    end

    it "tags the schema endpoint as the machine-readable service-desc" do
      declare_query("catalog")
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      schema = member(d)[:item].find { |i| i[:href].end_with?("/schema") }
      expect(schema[:rel]).to eq("service-desc")
    end

    it "advertises the DERIVED openapi.json beside it — the only place it is advertised" do
      # T-071 = C. RFC 8631 allows more than one `service-desc`; the canonical
      # bespoke catalog stays FIRST, and the derived document — which the skill
      # names nowhere — follows it. This item and the renderer are the whole of
      # the provisional surface.
      declare_query("catalog")
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      descs = member(d)[:item].select { |i| i[:rel] == "service-desc" }.map { |i| i[:href] }

      expect(descs).to eq(["https://api.acme.example/kiosk/schema",
                           "https://api.acme.example/kiosk/openapi.json"])
    end

    it "advertises no openapi.json when there is nothing to describe" do
      hrefs = member(doc)[:item].map { |i| i[:href] }
      expect(hrefs).not_to include("https://api.acme.example/kiosk/openapi.json")
    end

    it "tags the one remaining non-description wire endpoint — `pay` — with rel=item" do
      # `service-desc` is for the two documents that DESCRIBE the API; a live
      # API endpoint is a plain catalogued `item`. Since the cutover `pay` is
      # the only one of those left with a single URL to link.
      declare_action("checkout")
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.api_catalog(base_url: "https://api.acme.example")
      pay = d[:linkset].first[:item].find { |i| i[:href].end_with?("/pay") }
      expect(pay[:rel]).to eq("item")
    end

    it "links the agents.json discovery companion" do
      hrefs = member(doc)[:item].map { |i| i[:href] }
      expect(hrefs).to include("https://api.acme.example/agents.json")
    end

    it "respects an overridden mount_path for the wire endpoints" do
      declare_query("catalog")
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

  end
end
