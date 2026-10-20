# frozen_string_literal: true

# DiscoveryController request specs (0.2 standards alignment, W1/W3).
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require 'rack/mock'
require 'json'
require 'json_schemer'

RSpec.shared_context 'with the acme origin for discovery' do
  def dispatch(action, path, **)
    status, headers, body = Kiosk::Server::DiscoveryController.action(action).call(
      Rack::MockRequest.env_for("https://api.acme.example#{path}", **)
    )
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, raw]
  end

  before do
    Kiosk.configure do |c|
      c.issuer = 'https://api.acme.example'
      c.owner  = { name: 'Acme Inc.', support: 'support@acme.example' }
      # Serve `pay`, so the documents are checked where every module is live.
      c.payment_provider = Object.new
      c.skill_sha256 = 'a' * 64
    end
  end

  # The published schema each document names, kept under spec/support/standards.
  def conforms?(document, schema, ref: nil)
    path = File.expand_path("../../support/standards/#{schema}", __dir__)
    schemer = JSONSchemer.schema(JSON.parse(File.read(path)))
    schemer = schemer.ref(ref) if ref
    errors = schemer.validate(document).map { |e| e['error'] }
    expect(errors).to be_empty, errors.join("\n")
  end
end

RSpec.describe 'DiscoveryController' do
  include_context 'with the acme origin for discovery'

  describe 'GET /agents.txt' do
    it 'returns 200 text/plain with the directives + CORS' do
      status, headers, raw = dispatch(:agents_txt, '/agents.txt')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('text/plain; charset=utf-8')
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
      expect(raw).to include("\nAuthorization: x-kiosk-pop\n")
      # base_url comes from the request
      expect(raw).to include('# JSON: https://api.acme.example/agents.json')
    end

    # agents.txt v1.0 §3.1 and §8-§11: only the registered directives, and
    # each identifier registered or `x-` prefixed.
    it 'carries only registered directives with registered or x- identifiers' do
      _, _, raw = dispatch(:agents_txt, '/agents.txt')
      lines = raw.lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
      directives = %w[Protocols Payments Authorization Identity MCP Skills A2A UCP WebMCP]
      expect(lines.map { |l| l.split(':', 2).first } - directives).to be_empty
      ids = lines.grep(/\AAuthorization:/).flat_map { |l| l.split(':', 2).last.split(',').map(&:strip) }
      expect(ids).to all(match(/\A(agent-auth|oauth2|auth-md|x-.+)\z/))
    end
  end

  describe 'GET /agents.json' do
    it 'returns 200 application/json + CORS, valid against the agents.json v1.0 schema' do
      status, headers, raw = dispatch(:agents_json, '/agents.json')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to include('application/json')
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
      conforms?(JSON.parse(raw), 'agents-json-v1.0.schema.json')
    end
  end

  describe 'GET /.well-known/oauth-authorization-server' do
    it 'returns the RFC 8414 metadata, its endpoints on this origin' do
      status, headers, raw = dispatch(:oauth_authorization_server, '/.well-known/oauth-authorization-server')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to include('application/json')
      doc = JSON.parse(raw)
      # RFC 8414 §2: issuer and response_types_supported are REQUIRED, and a
      # server with no authorization endpoint names no response type.
      expect(doc).to include('issuer' => 'https://api.acme.example', 'response_types_supported' => [])
      expect(doc.values_at('token_endpoint', 'device_authorization_endpoint', 'jwks_uri'))
        .to all(start_with('https://api.acme.example/kiosk/'))
    end

    it 'answers 404 where the origin serves no account binding' do
      Kiosk.configure { |c| c.serve_account_binding = false }
      status, = dispatch(:oauth_authorization_server, '/.well-known/oauth-authorization-server')
      expect(status).to eq(404)
    end
  end

  describe 'GET /.well-known/agent-skills/index.json' do
    it 'returns the index, valid against Agent Skills Discovery v0.2.0' do
      status, headers, raw = dispatch(:agent_skills_index, '/.well-known/agent-skills/index.json')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to include('application/json')
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
      conforms?(JSON.parse(raw), 'agent-skills-index-0.2.0.schema.json')
    end

    it 'answers 404 when no skill digest is pinned' do
      Kiosk.configure { |c| c.skill_sha256 = nil }
      status, = dispatch(:agent_skills_index, '/.well-known/agent-skills/index.json')
      expect(status).to eq(404)
    end
  end

  describe 'GET /.well-known/ard.json' do
    it 'returns the manifest, valid against the ARD v0.91 schema' do
      status, headers, raw = dispatch(:ard, '/.well-known/ard.json')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to include('application/json')
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
      conforms?(JSON.parse(raw), 'ard-entry.schema.json', ref: '#/$defs/ArdManifest')
    end
  end

  describe 'GET /auth.md' do
    it 'returns 200 text/markdown with the auth.md body + CORS' do
      status, headers, raw = dispatch(:auth_md, '/auth.md')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('text/markdown; charset=utf-8')
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
      # Byte-identical to the renderer (single generator seam).
      expect(raw).to eq(Kiosk::Server::WellKnown.auth_md(base_url: 'https://api.acme.example'))
      expect(raw).to include('## Pick a method')
      expect(raw.lines.first).to match(/\A# .*auth\.md/)
    end
  end

  describe 'GET /.well-known/kiosk.json' do
    it 'returns 200 application/json byte-identical to WellKnown.build_json' do
      status, headers, raw = dispatch(:kiosk_json, '/.well-known/kiosk.json')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to include('application/json')
      # Regression guard: the derived alias must be byte-for-byte the current
      # bespoke document.
      expected = Kiosk::Server::WellKnown.build_json(base_url: 'https://api.acme.example')
      expect(raw).to eq(expected)
    end
  end

  describe 'GET /.well-known/api-catalog' do
    it 'returns 200 application/linkset+json (RFC 9727), valid against RFC 9264, with its Link header' do
      declare_query('catalog')
      status, headers, raw = dispatch(:api_catalog, '/.well-known/api-catalog')
      expect(status).to eq(200)
      expect(headers['Content-Type']).to include('application/linkset+json')
      # The RFC 9727 profile parameter identifies the api-catalog media type.
      expect(headers['Content-Type']).to include('profile="https://www.rfc-editor.org/info/rfc9727"')
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
      # RFC 9727 §2: a HEAD finds the catalog through this header.
      expect(headers['Link']).to eq('<https://api.acme.example/.well-known/api-catalog>; rel="api-catalog"')
      doc = JSON.parse(raw)
      conforms?(doc, 'rfc9264-linkset.schema.json')
      expect(doc.dig('linkset', 0, 'item')).to include('href' => 'https://api.acme.example/kiosk/catalog',
                                                       'kiosk-method' => ['GET'])
    end
  end

  # ─── the cache policy of the POINTER documents ───────────────────────────
  #
  # `max-age=60` (settled 2026-08-19), not because a minute is efficient but
  # because a minute is how long an operator must live with the previous
  # document after a deploy. The load these documents would otherwise carry is
  # carried by the immutable `?v=` url they point at.
  describe 'the public cache policy' do
    it 'serves the four pointer documents public, one minute' do
      declare_query('catalog')
      %i[agents_json kiosk_json api_catalog ard].each do |action|
        _status, headers, = dispatch(action, '/x')
        expect(headers['Cache-Control']).to eq(Kiosk::Server::Headers::PUBLIC_SHORT)
        expect(headers['Cache-Control']).to eq('max-age=60, public')
      end
    end

    # NO Vary ON A PUBLIC DOCUMENT. These are public and identical for
    # every caller, so there is nothing for a cache to vary on.
    # None of them reads a request header, so none of them varies. Rails
    # disagrees unless stopped: `_set_vary_header` stamps `Vary: Accept` on
    # any render negotiated from a non-blank `Accept`, which is what a real
    # client sends and what a bare MockRequest does NOT — so the negotiated
    # half is the half that matters.
    it 'emits no Vary on any of them, negotiated or not' do
      declare_query('catalog')
      actions = { agents_txt: '/agents.txt', agents_json: '/agents.json',
                  oauth_authorization_server: '/.well-known/oauth-authorization-server',
                  agent_skills_index: '/.well-known/agent-skills/index.json', ard: '/.well-known/ard.json',
                  kiosk_json: '/.well-known/kiosk.json',
                  api_catalog: '/.well-known/api-catalog', auth_md: '/auth.md' }
      actions.each do |action, path|
        _status, plain, = dispatch(action, path)
        _status, negotiated, = dispatch(action, path, 'HTTP_ACCEPT' => 'application/json')
        expect(plain['Vary']).to be_nil, "#{action} varies (unnegotiated)"
        expect(negotiated['Vary']).to be_nil, "#{action} varies (Accept: application/json)"
      end
    end
  end
end
