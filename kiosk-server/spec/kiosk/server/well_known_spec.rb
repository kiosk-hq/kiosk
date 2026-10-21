# frozen_string_literal: true

require 'json'

module WellKnownSpec
  # Parse the non-comment, non-blank lines into a Key => value hash.
  def directives(text)
    text.each_line.filter_map do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, _, value = line.partition(':')
      [key.strip, value.strip]
    end.to_h
  end

  # The linkset's first member: anchored at the api-catalog URL, carrying
  # the `item` link array.
  def member(linkset) = linkset[:linkset].first

  # The `?v=` both descriptions carry. This document is a pointer with a short
  # TTL; the two it points at are immutable at their versioned url. Derived
  # here, because the digest moves with the registry these examples register
  # into.
  def v = "?v=#{Kiosk::Server::SchemaDocument.digest}"
end

RSpec.shared_context 'with the acme origin for well-known documents' do
  include WellKnownSpec

  before do
    Kiosk.configure do |c|
      c.issuer = 'https://api.acme.example'
      c.owner  = { name: 'Acme Inc.', support: 'support@acme.example' }
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'with the acme origin for well-known documents'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

    it 'wraps everything under a top-level `kiosk` key' do
      expect(doc.keys).to eq([:kiosk])
    end

    it 'advertises the document schema version' do
      expect(doc[:kiosk][:version]).to eq(described_class::DOCUMENT_VERSION)
    end

    it 'computes the endpoint as base_url + mount_path' do
      expect(doc[:kiosk][:endpoint]).to eq('https://api.acme.example/kiosk')
    end

    it 'respects an overridden mount_path' do
      Kiosk.configure { |c| c.mount_path = '/agent-surface' }
      d = described_class.build(base_url: 'https://api.acme.example')
      expect(d[:kiosk][:endpoint]).to eq('https://api.acme.example/agent-surface')
    end

    it 'strips trailing slashes from base_url' do
      d = described_class.build(base_url: 'https://api.acme.example/')
      expect(d[:kiosk][:endpoint]).to eq('https://api.acme.example/kiosk')
    end

    it 'advertises the five auth endpoints under the same origin, in this order' do
      expect(doc[:kiosk][:auth]).to eq(
        registration_url: 'https://api.acme.example/kiosk/oauth/register',
        token_url: 'https://api.acme.example/kiosk/oauth/token',
        rotate_url: 'https://api.acme.example/kiosk/auth/rotate',
        device_authorization_url: 'https://api.acme.example/kiosk/oauth/device_authorization',
        claim_url: 'https://api.acme.example/kiosk/auth/claim'
      )
      expect(doc[:kiosk][:auth].keys.first).to eq(:registration_url)
    end

    it 'advertises the binding endpoints also where the origin serves no binding (they answer 501)' do
      Kiosk.configure { |c| c.serve_account_binding = false }
      expect(described_class.build(base_url: 'https://api.acme.example')[:kiosk][:auth].keys.size).to eq(5)
    end

    # capabilities is computed from the live registry: empty here
    # since this context registers no queries/actions and wires no payment.
    it 'advertises an empty capability set when nothing is registered' do
      expect(doc[:kiosk][:capabilities]).to eq([])
    end

    it 'advertises the computed module names (schema/queries/actions/pay)' do
      declare_query('catalog')
      declare_action('checkout')
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.build(base_url: 'https://api.acme.example')
      expect(d[:kiosk][:capabilities]).to eq(%w[schema queries actions pay])
    end

    # `kiosk.json` is a POINTER, not a copy of the contract. An assistant
    # reads the module set here and the names from the catalog, and each of
    # those is published in exactly one place.
    it 'never names a registered verb in this document — pointer, not copy' do
      declare_query('secret_pricing_tiers')
      declare_action('cancel_enterprise_contract')
      d = described_class.build(base_url: 'https://api.acme.example')
      expect(JSON.generate(d)).not_to include('secret_pricing_tiers')
      expect(JSON.generate(d)).not_to include('cancel_enterprise_contract')
    end

    # ── THE CACHE-BUSTED CATALOG LINK ────────────────────────────────────
    #
    # This document is the SHORT-lived half of the asset-pipeline pair: it
    # expires in minutes and republishes the link, which is what lets
    # `/kiosk/schema?v=<digest>` be cached for a year.
    it 'links the catalog at its digest-versioned, immutable URL' do
      declare_query('catalog')
      d = described_class.build(base_url: 'https://api.acme.example')
      digest = Kiosk::Server::SchemaDocument.digest

      expect(d[:kiosk][:schema_url])
        .to eq("https://api.acme.example/kiosk/schema?v=#{digest}")
      expect(digest).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'moves that link when the catalog moves — that is the whole mechanism' do
      declare_query('catalog')
      before_add = described_class.build(base_url: 'https://api.acme.example')[:kiosk][:schema_url]

      declare_action('checkout')
      after_add = described_class.build(base_url: 'https://api.acme.example')[:kiosk][:schema_url]

      expect(after_add).not_to eq(before_add)
    end

    it "advertises kiosk-core's MIN_CLIENT as min_client" do
      expect(doc[:kiosk][:min_client]).to eq(Kiosk::Protocol::MIN_CLIENT)
    end

    it 'advertises the configured issuer' do
      expect(doc[:kiosk][:issuer]).to eq('https://api.acme.example')
    end

    it 'advertises the configured owner' do
      expect(doc[:kiosk][:owner][:name]).to    eq('Acme Inc.')
      expect(doc[:kiosk][:owner][:support]).to eq('support@acme.example')
    end

    it 'omits the skill block when skill_sha256 is not set' do
      expect(doc[:kiosk]).not_to have_key(:skill)
    end

    # The default URL literal lives in exactly ONE place: the
    # `@skill_url ||=` in configuration_extension.rb. This example holds the
    # WIRING (the discovery document advertises the configured default) plus
    # the property that makes a pin verifiable: the default names an
    # IMMUTABLE versioned cut, never the mutable `skill.md` alias.
    #
    # Which version that is belongs to kiosk-test-support's skill_pin_spec,
    # which holds it against the bytes kiosk.tech actually publishes.
    it 'advertises the skill descriptor when skill_sha256 is set' do
      Kiosk.configure { |c| c.skill_sha256 = 'abc123' }
      d = described_class.build(base_url: 'https://api.acme.example')
      expect(d[:kiosk][:skill]).to eq(url: Kiosk.configuration.skill_url, sha256: 'abc123')
      expect(Kiosk.configuration.skill_url)
        .to match(%r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z})
    end

    it 'respects an overridden skill_url' do
      Kiosk.configure do |c|
        c.skill_url    = 'https://kiosk.tech/skill-v1.1.md'
        c.skill_sha256 = 'def456'
      end
      d = described_class.build(base_url: 'https://api.acme.example')
      expect(d[:kiosk][:skill]).to eq(url: 'https://kiosk.tech/skill-v1.1.md', sha256: 'def456')
    end

    it 'raises if issuer is not configured' do
      Kiosk.reset!
      expect { described_class.build(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end

    it 'raises if issuer is an empty string' do
      Kiosk.configure { |c| c.issuer = '' }
      expect { described_class.build(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end
  end

  describe '.build_json' do
    it 'returns a parse-able JSON string' do
      json = described_class.build_json(base_url: 'https://api.acme.example')
      parsed = JSON.parse(json)
      expect(parsed.dig('kiosk', 'endpoint')).to eq('https://api.acme.example/kiosk')
    end
  end

  # ─── W1: agents.txt native discovery envelope ────────────────────────────
  describe '.agents_txt' do
    subject(:body) { described_class.agents_txt(base_url: 'https://api.acme.example') }

    it 'returns a String' do
      expect(body).to be_a(String)
    end

    it 'names OAuth 2.0 by the identifier agents.txt registers for it' do
      expect(directives(body)).to eq('Authorization' => 'oauth2',
                                     'Skills' => Kiosk.configuration.skill_url)
    end

    # The AP2 v0.1-shaped mandates are not the AP2 protocol agents.txt names,
    # and `Payments: required` means no free path; `schema` is one.
    it 'declares no payment protocol, even where the operator serves pay' do
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = directives(described_class.agents_txt(base_url: 'https://api.acme.example'))
      expect(d.keys).to eq(%w[Authorization Skills])
    end

    it 'emits a Skills directive pointing at the configured skill URL' do
      # Deliberately synthetic (not a published kiosk.tech artifact): this is a
      # round-trip on whatever skill_url is configured, and a synthetic value
      # cannot go stale — and cannot be mistaken for the shipped default, which
      # is asserted separately above.
      Kiosk.configure { |c| c.skill_url = 'https://example.test/skill.md' }
      d = directives(described_class.agents_txt(base_url: 'https://api.acme.example'))
      expect(d['Skills']).to eq('https://example.test/skill.md')
    end

    it 'has a `#` comment header and a JSON pointer comment' do
      expect(body).to match(/\A#/)
      expect(body).to include('# JSON: https://api.acme.example/agents.json')
    end

    it 'every non-comment, non-blank line is a `Key: value` directive' do
      body.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')

        expect(line).to match(/\A[A-Za-z][\w-]*:\s?.+\z/)
      end
    end

    it 'validates the issuer (same contract as build)' do
      Kiosk.reset!
      expect { described_class.agents_txt(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end
  end

  # ─── W1: agents.json native discovery companion ──────────────────────────
  describe '.agents_json' do
    subject(:doc) { described_class.agents_json(base_url: 'https://api.acme.example') }

    it 'carries the agents.json v1.0 required keys' do
      expect(doc[:version]).to eq('1.0')
      expect(doc[:standard]).to be_a(String)
      expect(doc[:site]).to include(:name, :url)
    end

    it 'derives site.url from the base_url and site.name from the owner' do
      expect(doc[:site][:url]).to eq('https://api.acme.example')
      expect(doc[:site][:name]).to eq('Acme Inc.')
    end

    it 'falls back to the issuer host for site.name when no owner name is set' do
      Kiosk.configure { |c| c.owner = {} }
      d = described_class.agents_json(base_url: 'https://api.acme.example')
      expect(d[:site][:name]).to eq('api.acme.example')
    end

    it 'declares no payments block, even where the operator serves pay' do
      Kiosk.configure { |c| c.payment_provider = Object.new }
      expect(described_class.agents_json(base_url: 'https://api.acme.example')).not_to have_key(:payments)
    end

    it 'advertises OAuth 2.0 with the RFC 8414 metadata as its discovery document' do
      expect(doc[:authorization]).to eq(protocols: %w[oauth2], discovery: '/.well-known/oauth-authorization-server')
    end

    it 'lists the configured skill' do
      # Synthetic on purpose — round-trip of the configured value, immune to
      # published-skill version bumps. The shipped default is pinned
      # and asserted in the skill-descriptor example above.
      Kiosk.configure { |c| c.skill_url = 'https://example.test/skill.md' }
      d = described_class.agents_json(base_url: 'https://api.acme.example')
      expect(d[:skills].first[:url]).to eq('https://example.test/skill.md')
    end

    # Same rule, same NEW reason as kiosk.json above: a pointer, not a copy.
    it 'never names a registered verb in this companion — pointer, not copy' do
      declare_query('secret_pricing_tiers')
      d = described_class.agents_json(base_url: 'https://api.acme.example')
      expect(JSON.generate(d)).not_to include('secret_pricing_tiers')
    end

    it 'names the agents.json v1.0 schema' do
      expect(doc[:$schema]).to eq('https://agents-txt.com/schema/agents-json/v1.0.json')
    end
  end

  # ─── /.well-known/oauth-authorization-server (RFC 8414) ─────────────────
  describe '.oauth_authorization_server' do
    subject(:doc) { described_class.oauth_authorization_server(base_url: 'https://api.acme.example') }

    it 'names the issuer, registration, the token endpoint and the device-code grant' do
      expect(doc).to eq(
        issuer: 'https://api.acme.example',
        registration_endpoint: 'https://api.acme.example/kiosk/oauth/register',
        token_endpoint: 'https://api.acme.example/kiosk/oauth/token',
        device_authorization_endpoint: 'https://api.acme.example/kiosk/oauth/device_authorization',
        jwks_uri: 'https://api.acme.example/kiosk/.well-known/jwks.json',
        response_types_supported: [],
        grant_types_supported: ['client_credentials', 'urn:ietf:params:oauth:grant-type:device_code'],
        token_endpoint_auth_methods_supported: ['private_key_jwt'],
        token_endpoint_auth_signing_alg_values_supported: ['RS256'],
        service_documentation: 'https://api.acme.example/auth.md',
        dpop_signing_alg_values_supported: ['RS256']
      )
    end

    it 'leaves out the device-code grant where the origin serves no account binding' do
      Kiosk.configure { |c| c.serve_account_binding = false }
      expect(doc).not_to have_key(:device_authorization_endpoint)
      expect(doc[:grant_types_supported]).to eq(['client_credentials'])
    end

    it 'reads every algorithm list from AssistantKey::ALGORITHMS' do
      stub_const('Kiosk::Server::AssistantKey::ALGORITHMS', %w[RS256 ES256])
      expect(doc.values_at(:token_endpoint_auth_signing_alg_values_supported, :dpop_signing_alg_values_supported))
        .to eq([%w[RS256 ES256], %w[RS256 ES256]])
    end

    it 'validates the issuer (same contract as build)' do
      Kiosk.reset!
      expect { doc }.to raise_error(ArgumentError, /issuer/)
    end
  end

  # ─── /.well-known/agent-skills/index.json (Agent Skills Discovery) ───────
  describe '.agent_skills_index' do
    it 'lists the pinned skill with its digest' do
      Kiosk.configure { |c| c.skill_sha256 = 'a' * 64 }
      expect(described_class.agent_skills_index).to eq(
        '$schema': 'https://schemas.agentskills.io/discovery/0.2.0/schema.json',
        skills: [{ name: 'kiosk-agent-protocol', type: 'skill-md',
                   description: described_class::SKILL_DESCRIPTION,
                   url: Kiosk.configuration.skill_url, digest: "sha256:#{'a' * 64}" }]
      )
    end

    it 'is nil without a pinned digest, which every entry requires' do
      expect(described_class.agent_skills_index).to be_nil
    end
  end

  # ─── /.well-known/ard.json (Agentic Resource Discovery) ──────────────────
  describe '.ard' do
    subject(:doc) { described_class.ard(base_url: 'https://api.acme.example') }

    it 'lists kiosk.json and the skill, each under a URN of this host' do
      expect(doc[:entries].map { |e| e.values_at(:identifier, :type, :url) }).to eq(
        [['urn:air:api.acme.example:kiosk:api', 'application/json', 'https://api.acme.example/.well-known/kiosk.json'],
         ['urn:air:api.acme.example:kiosk:skill', 'application/agent-skills+md', Kiosk.configuration.skill_url]]
      )
    end

    it 'lists kiosk.json alone at an origin advertising no skill' do
      Kiosk.configure { |c| c.skill_url = '' }
      expect(doc[:entries].pluck(:identifier)).to eq(['urn:air:api.acme.example:kiosk:api'])
    end
  end

  # ─── W5: /auth.md (auth.md-vocabulary method description) ────────────────
  describe '.auth_md' do
    subject(:body) { described_class.auth_md(base_url: 'https://api.acme.example') }

    it 'follows the canonical auth.md section order' do
      sections = body.each_line.filter_map { |l| l.chomp[/\A## (.+)\z/, 1]&.strip }
      expect(sections).to eq([
                               'Discover', 'Pick a method', 'Register', 'Claim ceremony',
                               'Exchange', 'Use the access_token', 'Errors', 'Revocation'
                             ])
      expect(body).to start_with('# ')
    end

    # The heading the auth.md format and its scanners look for.
    it 'opens with an H1 that names auth.md' do
      expect(body.lines.first).to eq("# auth.md — Acme Inc.\n")
    end

    it 'names the OAuth standards of registration and tokens' do
      expect(body).to include('RFC 7591', 'RFC 7523', 'RFC 9449', 'RFC 8628')
    end

    it 'marks identity assertion (ID-JAG) as not supported / planned' do
      expect(body).to match(/Identity assertion \(ID-JAG\).*not supported \(planned\)/)
    end

    it 'points at the OAuth metadata' do
      expect(body).to include('https://api.acme.example/.well-known/oauth-authorization-server')
    end

    # ── The register step teaches the header PoW transport ──────────────────
    #
    # The server reads registration proofs ONLY from the `Kiosk-PoW` request
    # header ({OauthRegistrationController} → {PowGate.proofs_from_header}); a
    # `pow` key in the registration BODY is ignored, and an assistant that sent
    # one would get 402 forever. These two examples pin the served bytes.
    describe 'the Register step (PoW transport)' do
      subject(:register) { body[/^## Register$.*?(?=^## )/m] }

      it 'renders the RFC 7591 registration body with the key as a JWK Set — no body `pow`' do
        expect(register).to include('{"jwks":{"keys":[{"kty":"RSA","n":"…","e":"AQAB"}]},')
        expect(register).to include('201 { client_id')
        expect(body).not_to match(/\{[^}]*\bjwks\b[^}]*\bpow\b/)
      end

      it 'sends the proof in the `Kiosk-PoW` request header, never the body' do
        expect(register).to match(/`Kiosk-PoW`\s+REQUEST HEADER/)
        expect(register).to include('Kiosk-PoW: {')
        expect(register).to match(/A proof is never in the\s+request body/)
        # The RFC 7235 pair: the 402 names the scheme, the client answers in
        # the matching request header.
        expect(register).to include('402 pow_required')
        expect(register).to include(%(WWW-Authenticate: Kiosk-PoW realm="<issuer>"))
      end
    end

    # ── Cold-start pointers ─────────────────────────────────────────────────
    #
    # An assistant that discovers via auth.md reads this document before it
    # has a token, and the Equihash solve is the one step of the handshake it
    # cannot derive. So the document points at the skill and the solver.
    describe 'the Discover list (cold-start pointers)' do
      subject(:discover) { body[/^## Discover$.*?(?=^## )/m] }

      it 'names the wire skill, the same URL agents.txt advertises' do
        expect(discover).to include(Kiosk.configuration.skill_url)
        expect(described_class.agents_txt(base_url: 'https://api.acme.example'))
          .to include(Kiosk.configuration.skill_url)
      end

      it 'carries the skill digest when the operator configured one' do
        Kiosk.configure { |c| c.skill_sha256 = 'deadbeef' }
        expect(body[/^## Discover$.*?(?=^## )/m]).to include('sha256 `deadbeef`')
      end

      it 'omits the digest — not the pointer — when none is configured' do
        expect(Kiosk.configuration.skill_sha256).to be_nil
        expect(discover).to include(Kiosk.configuration.skill_url)
        expect(discover).not_to include('sha256')
      end

      it 'drops the bullet entirely at an origin advertising no skill' do
        Kiosk.configure { |c| c.skill_url = '' }
        expect(body[/^## Discover$.*?(?=^## )/m]).not_to include('Wire skill')
      end
    end

    describe 'the Register step (where the solver is)' do
      subject(:register) { body[/^## Register$.*?(?=^## )/m] }

      # ONE literal, in PowGate — the 403 hint and this document render the
      # same constant, so the document cannot come to point somewhere the
      # error message does not.
      it 'points at the published reference solver, the URL the 403 hint names' do
        expect(register).to include(Kiosk::Server::PowGate::POW_SOLVER_URL)
        expect(Kiosk::Server::PowGate::POW_INVALID_HINT)
          .to include(Kiosk::Server::PowGate::POW_SOLVER_URL)
      end

      it 'tells the reader not to hand-roll a solver and to check the digest first' do
        expect(register).to include('Do not write your own Equihash solver')
        expect(register).to match(/SHA-256.*pin/m)
      end
    end

    it 'advertises the ceremony endpoints as absolute URLs under the mount' do
      expect(body).to include('https://api.acme.example/kiosk/oauth/device_authorization')
      expect(body).to include('https://api.acme.example/kiosk/auth/claim')
      expect(body).to include('https://api.acme.example/kiosk/oauth/token')
      expect(body).to include('https://api.acme.example/kiosk/auth/unlink')
    end

    # The token vocabulary is NINE codes, and registration has one more.
    it 'documents the OAuth error vocabulary of the /oauth/* endpoints' do
      Kiosk::Server::OauthError::CODES.each { expect(body).to include("`#{it}`") }
    end

    # Every operator serves this document, and an assistant reads it to learn
    # how a refusal is shaped. Pinned by shape, not by prose.
    it 'teaches the RFC 9457 problem document, with the code FLAT' do
      expect(body).to include('RFC 9457 problem document')
      expect(body).to include('application/problem+json')
      expect(body).to include('https://kiosk.tech/problems/<code>')
      expect(body).to match(/`code`.*FLAT member/)
      # The retired envelope must not survive anywhere in the document.
      expect(body).not_to include('ok: false')
      expect(body).not_to include('JSON envelope')
    end

    it 'requires a client assertion and a DPoP proof on every token request' do
      exchange = body[/^## Exchange$.*?(?=^## )/m]
      expect(exchange).to include('grant_type=client_credentials', '`client_assertion`', '`DPoP` header')
      expect(exchange).to match(/token\s+request has no `ath`/)
    end

    it 'states the reputation-carry rule (claiming never whitewashes)' do
      expect(body).to include('keeps your `client_id` and your reputation')
    end

    it 'validates the issuer (same contract as build)' do
      Kiosk.reset!
      expect { described_class.auth_md(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end
  end

  # ─── W-catalog: /.well-known/api-catalog (RFC 9727 linkset) ──────────────
  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    def descs(linkset) = linkset[:linkset].find { |m| m.key?(:'service-desc') }&.dig(:'service-desc')

    it 'anchors the items at the api-catalog URL' do
      expect(member(doc)[:anchor]).to eq('https://api.acme.example/.well-known/api-catalog')
    end

    it 'links every registered verb, then pay, as an item with its method' do
      declare_query('catalog')
      declare_action('checkout')
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      expect(member(d)[:item]).to eq(
        [{ href: 'https://api.acme.example/kiosk/catalog', 'kiosk-method': ['GET'] },
         { href: 'https://api.acme.example/kiosk/checkout', 'kiosk-method': ['POST'] },
         { href: 'https://api.acme.example/kiosk/pay', 'kiosk-method': ['POST'] }]
      )
    end

    # The fixture verbs are named to sound like secrets. They are not: this
    # document is a render of in-process state, so it caches behind a CDN and
    # anonymous enumeration costs the origin nothing.
    it 'hyperlinks EVERY registered verb, at its own endpoint, unauthenticated' do
      declare_query('secret_pricing_tiers')
      declare_action('cancel_enterprise_contract')
      hrefs = member(described_class.api_catalog(base_url: 'https://api.acme.example'))[:item].pluck(:href)
      expect(hrefs).to eq(%w[https://api.acme.example/kiosk/secret_pricing_tiers
                             https://api.acme.example/kiosk/cancel_enterprise_contract])
    end

    # RFC 9727 Appendix A.1: a description is a `service-desc` link of the API.
    it 'links the two versioned descriptions from the endpoint' do
      declare_query('catalog')
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      expect(d[:linkset].last).to eq(
        anchor: 'https://api.acme.example/kiosk',
        'service-desc': [{ href: "https://api.acme.example/kiosk/schema#{v}", type: 'application/json' },
                         { href: "https://api.acme.example/kiosk/openapi.json#{v}",
                           type: Kiosk::Server::OpenApi::CONTENT_TYPE }]
      )
    end

    it 'links nothing when nothing is registered' do
      expect(doc).to eq(linkset: [{ anchor: 'https://api.acme.example/.well-known/api-catalog', item: [] }])
      expect(descs(doc)).to be_nil
    end

    it 'omits pay when the origin serves none' do
      declare_query('catalog')
      hrefs = member(described_class.api_catalog(base_url: 'https://api.acme.example'))[:item].pluck(:href)
      expect(hrefs).not_to include('https://api.acme.example/kiosk/pay')
    end

    # Publishing every verb is acceptable only while the document is CHEAP
    # AND STATIC to compose: every member comes from in-process state.
    it 'composes from the registry alone — no per-request work to widen it' do
      declare_query('catalog')
      declare_action('checkout')

      allow(Kiosk::Server::Queries).to receive(:known).and_call_original
      allow(Kiosk::Server::Actions).to receive(:known).and_call_original
      described_class.api_catalog(base_url: 'https://api.acme.example')
      expect(Kiosk::Server::Queries).to have_received(:known).at_least(:once)
      expect(Kiosk::Server::Actions).to have_received(:known).at_least(:once)
    end

    it 'respects an overridden mount_path' do
      declare_query('catalog')
      Kiosk.configure { |c| c.mount_path = '/agent-surface' }
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      expect(descs(d).first[:href]).to eq("https://api.acme.example/agent-surface/schema#{v}")
    end

    it 'strips trailing slashes from base_url' do
      d = described_class.api_catalog(base_url: 'https://api.acme.example/')
      expect(member(d)[:anchor]).to eq('https://api.acme.example/.well-known/api-catalog')
    end

    it 'validates the issuer (same contract as build)' do
      Kiosk.reset!
      expect { described_class.api_catalog(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end
  end
end
