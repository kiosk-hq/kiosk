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

  # The linkset's single member: anchored at the api-catalog URL, carrying
  # the `item` link array.
  def member(linkset) = linkset[:linkset].first

  # The `?v=` both descriptions carry. This document is a pointer with a short
  # TTL; the two it points at are immutable at their versioned url. Derived
  # here, because the digest moves with the registry these examples register
  # into.
  def v = "?v=#{Kiosk::Server::SchemaDocument.digest}"
end

RSpec.shared_context 'well known spec: acme origin' do
  include WellKnownSpec

  before do
    Kiosk.configure do |c|
      c.issuer = 'https://api.acme.example'
      c.owner  = { name: 'Acme Inc.', support: 'support@acme.example' }
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

    it 'advertises the proof-of-possession auth surface under the same origin' do
      expect(doc[:kiosk][:auth][:kind]).to          eq('kiosk-pop')
      expect(doc[:kiosk][:auth][:challenge_url]).to eq('https://api.acme.example/kiosk/auth/challenge')
      expect(doc[:kiosk][:auth][:register_url]).to  eq('https://api.acme.example/kiosk/auth/register')
      expect(doc[:kiosk][:auth][:login_url]).to     eq('https://api.acme.example/kiosk/auth/login')
      expect(doc[:kiosk][:auth][:revoke_url]).to    eq('https://api.acme.example/kiosk/auth/revoke')
    end

    it 'does not advertise a legacy OAuth surface' do
      expect(doc[:kiosk][:auth]).not_to have_key(:authorize_url)
      expect(doc[:kiosk][:auth]).not_to have_key(:token_url)
    end

    it 'advertises the account-binding endpoints (additive keys)' do
      expect(doc[:kiosk][:auth][:device_authorization_url])
        .to eq('https://api.acme.example/kiosk/oauth/device_authorization')
      expect(doc[:kiosk][:auth][:claim_url])
        .to eq('https://api.acme.example/kiosk/auth/claim')
    end

    it 'keeps the pre-binding auth keys first and byte-identical (additive-only rule)' do
      expect(doc[:kiosk][:auth].keys.first(5))
        .to eq(%i[kind challenge_url register_url login_url revoke_url])
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build' do
    subject(:doc) { described_class.build(base_url: 'https://api.acme.example') }

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
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.build_json' do
    it 'returns a parse-able JSON string' do
      json = described_class.build_json(base_url: 'https://api.acme.example')
      parsed = JSON.parse(json)
      expect(parsed.dig('kiosk', 'endpoint')).to eq('https://api.acme.example/kiosk')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  # ─── W1: agents.txt native discovery envelope ────────────────────────────
  describe '.agents_txt' do
    subject(:body) { described_class.agents_txt(base_url: 'https://api.acme.example') }

    it 'returns a String' do
      expect(body).to be_a(String)
    end

    it 'carries the agents.txt v1.0 auth directives (auth-md alongside agent-auth)' do
      d = directives(body)
      expect(d['Authorization']).to eq('agent-auth auth-md')
      expect(d['Identity']).to eq('required')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_txt' do
    subject(:body) { described_class.agents_txt(base_url: 'https://api.acme.example') }

    # Payment directives are pay-conditional: emitted only when the
    # provider serves `pay` (a payment_provider is configured → `pay` is in the
    # computed capabilities).
    context 'when the provider serves pay (payment_provider configured)' do
      before { Kiosk.configure { |c| c.payment_provider = Object.new } }

      it 'carries the AP2 payment directives' do
        d = directives(described_class.agents_txt(base_url: 'https://api.acme.example'))
        expect(d['Protocols']).to eq('ap2')
        expect(d['Payments']).to eq('required')
      end
    end

    context 'when the provider serves no pay (no payment_provider)' do
      it 'omits the AP2 payment directives but keeps auth/identity' do
        # Bare config from the outer `before` registers no payment_provider →
        # capabilities excludes `pay`.
        expect(body).not_to include('Protocols: ap2')
        expect(body).not_to include('Payments: required')
        d = directives(body)
        expect(d['Authorization']).to eq('agent-auth auth-md')
        expect(d['Identity']).to eq('required')
      end
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_txt' do
    subject(:body) { described_class.agents_txt(base_url: 'https://api.acme.example') }

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_txt' do
    subject(:body) { described_class.agents_txt(base_url: 'https://api.acme.example') }

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
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_json' do
    subject(:doc) { described_class.agents_json(base_url: 'https://api.acme.example') }

    # The `payments` block is pay-conditional: present only when the
    # provider serves `pay` (payment_provider configured → `pay` in capabilities).
    # Optional in agents.json v1.0, so omitted otherwise.
    context 'when the provider serves pay (payment_provider configured)' do
      before { Kiosk.configure { |c| c.payment_provider = Object.new } }

      it 'declares AP2 payments as required' do
        d = described_class.agents_json(base_url: 'https://api.acme.example')
        expect(d[:payments][:required]).to be(true)
        expect(d[:payments]).to have_key(:ap2)
      end
    end

    context 'when the provider serves no pay (no payment_provider)' do
      it 'omits the payments key entirely' do
        # Bare config from the outer `before` registers no payment_provider →
        # capabilities excludes `pay`.
        expect(doc).not_to have_key(:payments)
      end
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_json' do
    subject(:doc) { described_class.agents_json(base_url: 'https://api.acme.example') }

    it 'advertises agent-auth + auth-md with the agent-configuration discovery pointer' do
      expect(doc[:authorization][:protocols]).to eq(%w[agent-auth auth-md])
      expect(doc[:authorization][:discovery]).to eq('/.well-known/agent-configuration')
      expect(doc[:authorization][:identity]).to eq('required')
    end

    it 'lists the configured skill' do
      # Synthetic on purpose — round-trip of the configured value, immune to
      # published-skill version bumps. The shipped default is pinned
      # and asserted in the skill-descriptor example above.
      Kiosk.configure { |c| c.skill_url = 'https://example.test/skill.md' }
      d = described_class.agents_json(base_url: 'https://api.acme.example')
      expect(d[:skills].first[:url]).to eq('https://example.test/skill.md')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_json' do
    subject(:doc) { described_class.agents_json(base_url: 'https://api.acme.example') }

    # The block carries POINTERS, not a copy of the
    # contract. Four keys, exactly.
    it 'carries the wire pointers under the x-kiosk extension' do
      declare_query('catalog')
      d = described_class.agents_json(base_url: 'https://api.acme.example')
      xk = d[:'x-kiosk']
      expect(xk.keys).to eq(%i[schema api_catalog mount_path api_version])
      # The pointer carries the same `?v=<digest>` cache-buster `kiosk.json`
      # publishes: a pointer a client may follow must point at the URL
      # that is safe to cache.
      expect(xk[:schema]).to eq("/kiosk/schema?v=#{Kiosk::Server::SchemaDocument.digest}")
      expect(xk[:api_catalog]).to eq('/.well-known/api-catalog')
      expect(xk[:mount_path]).to eq('/kiosk')
      expect(xk[:api_version]).to eq(Kiosk::Protocol::API_VERSION)
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_json' do
    subject(:doc) { described_class.agents_json(base_url: 'https://api.acme.example') }

    # It stopped echoing `capabilities` (the `wire.verbs` key is GONE): a
    # discovery envelope that restates the catalog is a second source of truth
    # for it, and `kiosk.json` is canonical. `min_client` went the same way.
    it 'does not echo capabilities or min_client under x-kiosk' do
      declare_query('catalog')
      d = described_class.agents_json(base_url: 'https://api.acme.example')
      xk = d[:'x-kiosk']
      expect(xk).not_to have_key(:wire)
      expect(xk).not_to have_key(:verbs)
      expect(xk).not_to have_key(:capabilities)
      expect(xk).not_to have_key(:min_client)
    end

    # Same rule, same NEW reason as kiosk.json above: a pointer, not a copy.
    it 'never names a registered verb in this companion — pointer, not copy' do
      declare_query('secret_pricing_tiers')
      d = described_class.agents_json(base_url: 'https://api.acme.example')
      expect(JSON.generate(d)).not_to include('secret_pricing_tiers')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agents_json' do
    subject(:doc) { described_class.agents_json(base_url: 'https://api.acme.example') }

    it 'points at the RFC 9727 api-catalog under the x-kiosk extension' do
      expect(doc[:'x-kiosk'][:api_catalog]).to eq('/.well-known/api-catalog')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  # ─── W3: /.well-known/agent-configuration (agent-auth discovery) ─────────
  describe '.agent_configuration' do
    subject(:doc) { described_class.agent_configuration(base_url: 'https://api.acme.example') }

    it 'advertises the issuer' do
      expect(doc[:issuer]).to eq('https://api.acme.example')
    end

    it 'lists the four auth endpoints as absolute URLs' do
      expect(doc[:endpoints][:challenge]).to eq('https://api.acme.example/kiosk/auth/challenge')
      expect(doc[:endpoints][:register]).to  eq('https://api.acme.example/kiosk/auth/register')
      expect(doc[:endpoints][:login]).to     eq('https://api.acme.example/kiosk/auth/login')
      expect(doc[:endpoints][:revoke]).to    eq('https://api.acme.example/kiosk/auth/revoke')
    end

    it 'points at the JWKS document' do
      expect(doc[:jwks_uri]).to eq('https://api.acme.example/kiosk/.well-known/jwks.json')
    end

    it 'declares kiosk-pop plus the binding modes' do
      expect(doc[:auth_modes]).to eq(%w[kiosk-pop user-claimed link-code])
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.agent_configuration' do
    subject(:doc) { described_class.agent_configuration(base_url: 'https://api.acme.example') }

    it 'points at /auth.md for the full method description' do
      expect(doc[:auth_md]).to eq('https://api.acme.example/auth.md')
    end

    it 'respects an overridden mount_path across all endpoints' do
      Kiosk.configure { |c| c.mount_path = '/agent-surface' }
      d = described_class.agent_configuration(base_url: 'https://api.acme.example')
      expect(d[:endpoints][:challenge]).to eq('https://api.acme.example/agent-surface/auth/challenge')
      expect(d[:jwks_uri]).to eq('https://api.acme.example/agent-surface/.well-known/jwks.json')
    end

    it 'validates the issuer (same contract as build)' do
      Kiosk.reset!
      expect { described_class.agent_configuration(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

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

    it 'presents kiosk-pop as anonymous-class + PoP upgrade — NEVER as Agent Verified' do
      expect(body).to match(/anonymous/i)
      expect(body).to match(/proof-of-possession/i)
      expect(body).not_to include('Agent Verified')
    end

    it 'marks identity assertion (ID-JAG) as not supported / planned' do
      expect(body).to match(/Identity assertion \(ID-JAG\).*not supported \(planned\)/)
    end

    it 'labels the link flow a Kiosk extension (auth.md has no human-initiated direction)' do
      expect(body).to match(/Link code.*Kiosk extension/m)
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.auth_md' do
    subject(:body) { described_class.auth_md(base_url: 'https://api.acme.example') }

    # ── The register step teaches the header PoW transport ──────────────────
    #
    # The server reads registration proofs ONLY from the `Kiosk-PoW` request
    # header ({AuthController#register} → {PowGate.proofs_from_header}); a
    # `pow` key in the register BODY is ignored, and an assistant that sent
    # one would get 402 forever. These two examples pin the served bytes.
    describe 'the Register step (PoW transport)' do
      subject(:register) { body[/^## Register$.*?(?=^## )/m] }

      it 'renders the register body as `{ public_key, signed }` — no body `pow`' do
        expect(register).to include('`{ public_key, signed }`')
        # No JSON-ish body example anywhere in the file may pair `signed`
        # with a `pow` field.
        expect(body).not_to match(/\{[^}]*\bsigned\b[^}]*\bpow\b/)
      end

      it 'sends the proof in the `Kiosk-PoW` request header, never the body' do
        expect(register).to match(/`Kiosk-PoW`\s+request header/i)
        expect(register).to include('Kiosk-PoW: {')
        expect(register).to match(/NEVER travels in the\s+request body/)
        # The RFC 7235 pair: the 402 names the scheme, the client answers in
        # the matching request header.
        expect(register).to include('402 pow_required')
        expect(register).to include(%(WWW-Authenticate: Kiosk-PoW realm="<issuer>"))
      end
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.auth_md' do
    subject(:body) { described_class.auth_md(base_url: 'https://api.acme.example') }

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
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.auth_md' do
    subject(:body) { described_class.auth_md(base_url: 'https://api.acme.example') }

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
        expect(register).to match(/Do not write your own Equihash solver/)
        expect(register).to match(/SHA-256.*pin/m)
      end
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.auth_md' do
    subject(:body) { described_class.auth_md(base_url: 'https://api.acme.example') }

    it 'advertises the ceremony endpoints as absolute URLs under the mount' do
      expect(body).to include('https://api.acme.example/kiosk/oauth/device_authorization')
      expect(body).to include('https://api.acme.example/kiosk/auth/claim')
      expect(body).to include('https://api.acme.example/kiosk/auth/login')
      expect(body).to include('https://api.acme.example/kiosk/auth/unlink')
    end

    # The vocabulary is EIGHT codes: the six RFC 8628 polling codes plus
    # `invalid_request` (spec §6.1 step 1 requires it for a `role`/`scope`
    # parameter) and `unsupported_grant_type`, all of which the engine emits.
    it 'documents the OAuth error vocabulary as the one exception' do
      %w[authorization_pending slow_down expired_token access_denied
         invalid_grant invalid_client invalid_request
         unsupported_grant_type].each do |code|
        expect(body).to include(code)
      end
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.auth_md' do
    subject(:body) { described_class.auth_md(base_url: 'https://api.acme.example') }

    # Every operator serves this document, and an assistant reads it to learn
    # how a refusal is shaped. Pinned by shape, not by prose.
    it 'teaches the RFC 9457 problem document, with the code FLAT' do
      expect(body).to include('RFC 9457 problem document')
      expect(body).to include('application/problem+json')
      expect(body).to include('https://kiosk.tech/problems/<code>')
      expect(body).to match(/`code`.*FLAT member/)
      # The retired envelope must not survive anywhere in the document.
      expect(body).not_to include('ok: false')
      expect(body).not_to match(/JSON envelope/)
    end

    it 'requires the possession proof in the token poll (BIND-POP is not optional)' do
      expect(body).to match(/`signed`.*possession proof/m)
      expect(body).to include('No binding happens without a valid possession proof')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.auth_md' do
    subject(:body) { described_class.auth_md(base_url: 'https://api.acme.example') }

    it 'states the reputation-carry rule (claiming never whitewashes)' do
      expect(body).to match(/reputation\s+carries over/)
    end

    it 'validates the issuer (same contract as build)' do
      Kiosk.reset!
      expect { described_class.auth_md(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  # ─── W-catalog: /.well-known/api-catalog (RFC 9727 linkset) ──────────────
  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'returns an RFC 9727 linkset anchored at the api-catalog URL' do
      expect(doc).to have_key(:linkset)
      expect(member(doc)[:anchor]).to eq('https://api.acme.example/.well-known/api-catalog')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'carries a non-empty item array of endpoint links' do
      items = member(doc)[:item]
      expect(items).to be_an(Array)
      expect(items).not_to be_empty
      expect(items).to all(include(:href, :rel))
    end

    it 'maps only the modules that still HAVE a single endpoint' do
      # A module holding N verbs has N endpoints, so the catalog links THE
      # VERBS (below) rather than a module URL that answers nothing.
      expect(described_class::MODULE_ENDPOINTS).to eq('pay' => 'pay')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'links the two descriptions, THEN every registered verb, then pay' do
      declare_query('catalog')
      declare_action('checkout')
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      hrefs = member(d)[:item].pluck(:href)
      # Every module is live here — schema, queries, actions AND pay. The two
      # `service-desc` members come first; then one `item` per registered
      # verb, at the endpoint the verb answers on.
      expect(hrefs).to eq(["https://api.acme.example/kiosk/schema#{v}",
                           "https://api.acme.example/kiosk/openapi.json#{v}",
                           'https://api.acme.example/kiosk/catalog',
                           'https://api.acme.example/kiosk/checkout',
                           'https://api.acme.example/kiosk/pay',
                           'https://api.acme.example/agents.json'])
      expect(hrefs).not_to include('https://api.acme.example/kiosk/query')
      expect(hrefs).not_to include('https://api.acme.example/kiosk/run')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'omits the endpoints of modules not present in capabilities' do
      # Register only a query → capabilities = [schema, queries]; the pay
      # module is absent, so its endpoint is not catalogued.
      declare_query('catalog')
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      hrefs = member(d)[:item].pluck(:href)
      expect(hrefs).to include("https://api.acme.example/kiosk/schema#{v}")
      expect(hrefs).not_to include('https://api.acme.example/kiosk/pay')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    # ── Verb names are public ────────────────────────────────────────────
    #
    # The fixture verbs are named to sound like secrets. They are not: this
    # document is a render of in-process state, so it caches behind a CDN and
    # anonymous enumeration costs the origin nothing. Asserted positively, so
    # it fails if the catalog stops publishing them.
    it 'hyperlinks EVERY registered verb, at its own endpoint, unauthenticated' do
      declare_query('secret_pricing_tiers')
      declare_action('cancel_enterprise_contract')
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      items = member(d)[:item]

      expect(items).to include(
        { href: 'https://api.acme.example/kiosk/secret_pricing_tiers',
          rel: 'item', 'kiosk-method': ['GET'] },
        { href: 'https://api.acme.example/kiosk/cancel_enterprise_contract',
          rel: 'item', 'kiosk-method': ['POST'] }
      )
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    # The METHOD is the half a bare href cannot carry, and it is not decorative:
    # a GET at an action's path is a 405. `kiosk-method` is an EXTENSION target
    # attribute, so RFC 9264 §4.2.4.3 serializes it as an array of strings.
    it 'says which METHOD reaches each verb — GET a query, POST an action' do
      declare_query('catalog')
      declare_action('checkout')
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      by_href = member(d)[:item].to_h { |i| [i[:href], i[:'kiosk-method']] }

      expect(by_href['https://api.acme.example/kiosk/catalog']).to eq(['GET'])
      expect(by_href['https://api.acme.example/kiosk/checkout']).to eq(['POST'])
      # A service description is not an operation and carries no method.
      expect(by_href["https://api.acme.example/kiosk/schema#{v}"]).to be_nil
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    # RFC 9727: a catalog lists APIs and points at their DESCRIPTIONS. So
    # both description members stay, and the operations are listed beside
    # them.
    it 'keeps both service-desc members — the operations are added, not swapped in' do
      declare_query('catalog')
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      descs = member(d)[:item].select { |i| i[:rel] == 'service-desc' }.pluck(:href)
      expect(descs).to eq(["https://api.acme.example/kiosk/schema#{v}",
                           "https://api.acme.example/kiosk/openapi.json#{v}"])
    end

    # Publishing every verb is acceptable only while the document is CHEAP
    # AND STATIC to compose: every member comes from in-process state.
    it 'composes from the registry alone — no per-request work to widen it' do
      declare_query('catalog')
      declare_action('checkout')

      expect(Kiosk::Server::Queries).to receive(:known).at_least(:once).and_call_original
      expect(Kiosk::Server::Actions).to receive(:known).at_least(:once).and_call_original
      described_class.api_catalog(base_url: 'https://api.acme.example')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'links no wire endpoints when nothing is registered (schema module absent)' do
      # Bare config registers no queries/actions → capabilities = []; only the
      # agents.json discovery companion is catalogued.
      hrefs = member(doc)[:item].pluck(:href)
      expect(hrefs).to eq(['https://api.acme.example/agents.json'])
    end

    it 'tags the schema endpoint as the machine-readable service-desc' do
      declare_query('catalog')
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      schema = member(d)[:item].find { |i| i[:href].start_with?('https://api.acme.example/kiosk/schema') }
      expect(schema[:href]).to eq("https://api.acme.example/kiosk/schema#{v}")
      expect(schema[:rel]).to eq('service-desc')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'advertises the DERIVED openapi.json beside it — the only place it is advertised' do
      # RFC 8631 allows more than one `service-desc`; the canonical
      # bespoke catalog stays FIRST, and the derived document — which the skill
      # names nowhere — follows it. This item and the renderer are the whole of
      # the provisional surface.
      declare_query('catalog')
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      descs = member(d)[:item].select { |i| i[:rel] == 'service-desc' }.pluck(:href)

      expect(descs).to eq(["https://api.acme.example/kiosk/schema#{v}",
                           "https://api.acme.example/kiosk/openapi.json#{v}"])
    end

    it 'advertises no openapi.json when there is nothing to describe' do
      hrefs = member(doc)[:item].pluck(:href)
      expect(hrefs.grep(%r{/kiosk/openapi\.json})).to be_empty
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'tags the one remaining non-description wire endpoint — `pay` — with rel=item' do
      # `service-desc` is for the two documents that DESCRIBE the API; a live
      # API endpoint is a plain catalogued `item`. Since the cutover `pay` is
      # the only one of those left with a single URL to link.
      declare_action('checkout')
      Kiosk.configure { |c| c.payment_provider = Object.new }
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      pay = d[:linkset].first[:item].find { |i| i[:href].end_with?('/pay') }
      expect(pay[:rel]).to eq('item')
    end

    it 'links the agents.json discovery companion' do
      hrefs = member(doc)[:item].pluck(:href)
      expect(hrefs).to include('https://api.acme.example/agents.json')
    end
  end
end

RSpec.describe Kiosk::Server::WellKnown do
  include_context 'well known spec: acme origin'

  describe '.api_catalog' do
    subject(:doc) { described_class.api_catalog(base_url: 'https://api.acme.example') }

    it 'respects an overridden mount_path for the wire endpoints' do
      declare_query('catalog')
      Kiosk.configure { |c| c.mount_path = '/agent-surface' }
      d = described_class.api_catalog(base_url: 'https://api.acme.example')
      hrefs = d[:linkset].first[:item].pluck(:href)
      expect(hrefs).to include("https://api.acme.example/agent-surface/schema#{v}")
    end

    it 'strips trailing slashes from base_url' do
      d = described_class.api_catalog(base_url: 'https://api.acme.example/')
      expect(d[:linkset].first[:anchor])
        .to eq('https://api.acme.example/.well-known/api-catalog')
    end

    it 'validates the issuer (same contract as build)' do
      Kiosk.reset!
      expect { described_class.api_catalog(base_url: 'https://api.acme.example') }
        .to raise_error(ArgumentError, /issuer/)
    end
  end
end
