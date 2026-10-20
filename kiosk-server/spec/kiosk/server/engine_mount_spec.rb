# frozen_string_literal: true

# The one-line adoption proof: a fresh Rails app whose ONLY Kiosk line is
#
#   mount Kiosk::Server::Engine => "/kiosk"
#
# must serve the full surface — wire + auth plane + JWKS + KYC + binding
# ceremony under the mount, and the ROOT-relative discovery documents
# (/agents.txt, /agents.json, /auth.md, /.well-known/*) installed by the
# engine's routes.append initializer. Three properties hold:
#
#   1. mounted        → full surface, end-to-end through the real Rack stack;
#   2. NOT mounted    → the gem is inert: bundling it adds NO routes;
#   3. a host line drawn ABOVE the mount wins (config/routes.rb precedes
#                       routes.append; Rails dispatches the first match), so
#                       the mount goes first.
#
# The probe app is a real, booted Rails::Application run ONCE as a SUBPROCESS
# (spec/support/engine_mount_probe_app.rb): booting Rails inside the suite
# process leaks Rails.logger and ActionDispatch::Flash into unrelated
# controller specs. This file asserts on the probe's JSON report.

require 'open3'

module EngineMountProbe
  PROBE = File.expand_path('../../support/engine_mount_probe_app.rb', __dir__)

  def self.report
    @report ||= begin
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, PROBE)
      unless status.success?
        raise "engine mount probe app failed (#{status.exitstatus}):\n" \
              "--- stdout ---\n#{stdout}\n--- stderr ---\n#{stderr}"
      end
      JSON.parse(stdout)
    end
  end
end

module EngineMountSpec
  THREE_HEADERS = %w[kiosk-server-version kiosk-api-version kiosk-min-client].freeze

  DECLINED_PATHS = [
    'POST /kiosk/oauth/device_authorization',
    'POST /kiosk/auth/claim',
    'POST /kiosk/oauth/token',
    'GET /kiosk/oauth/device/verify',
    'POST /kiosk/auth/link',
    'POST /kiosk/auth/unlink',
    'GET /kiosk/auth/assistants'
  ].freeze

  def probe(scenario, key = nil)
    scenario_report = EngineMountProbe.report.fetch(scenario)
    key ? scenario_report.fetch(key) : scenario_report
  end

  # The mounted scenario's answer to `request_line`, which must be a 200.
  def served(request_line)
    res = probe('mounted', request_line)
    expect(res['status']).to eq(200), "#{request_line}: got #{res['status']}"
    res
  end

  def three_headers = THREE_HEADERS

  def header_names(scenario, request_line)
    probe(scenario, request_line)['headers'].keys & three_headers
  end

  def issuer_on(key) = JSON.parse(probe('two_origins', key)['body']).dig('kiosk', 'issuer')
end

RSpec.describe Kiosk::Server::Engine do
  describe 'mount (the one-line surface)' do
    include EngineMountSpec

    context 'when the engine is mounted (fresh app, one line)' do
      it 'reports itself mounted' do
        expect(probe('mounted', 'mounted_in?')).to be(true)
      end

      it 'serves the root discovery documents end-to-end' do
        expect(served('GET /agents.txt')['body']).to include('http://localhost/agents.json')

        expect(JSON.parse(served('GET /agents.json')['body']).dig('site', 'url')).to eq('http://localhost')

        kiosk = JSON.parse(served('GET /.well-known/kiosk.json')['body']).fetch('kiosk')
        expect(kiosk['capabilities']).to include('queries')
        expect(kiosk['schema_url']).to match(%r{\Ahttp://localhost/kiosk/schema\?v=[0-9a-f]{32}\z})

        expect(JSON.parse(served('GET /.well-known/oauth-authorization-server')['body'])['token_endpoint'])
          .to eq('http://localhost/kiosk/oauth/token')
        expect(JSON.parse(served('GET /.well-known/ard.json')['body'])['entries']).not_to be_empty
        expect(probe('mounted', 'GET /.well-known/agent-skills/index.json')['status']).to eq(404)
        expect(served('GET /.well-known/api-catalog')['headers']['content-type']).to include('linkset+json')
        expect(served('GET /auth.md')['headers']['content-type']).to include('markdown')
      end

      it 'answers the schema_url of kiosk.json with the same document as the bare GET schema' do
        expect(served('GET /kiosk/schema?v= (schema_url)')['body']).to eq(served('GET /kiosk/schema')['body'])
      end

      it 'serves JWKS under the mount, stamped by the auto-injected middleware' do
        res = probe('mounted', 'GET /kiosk/.well-known/jwks.json')
        expect(res['status']).to eq(200)
        expect(JSON.parse(res['body']).fetch('keys')).not_to be_empty
        # HeadersMiddleware was injected by the engine initializer at boot; it
        # stamps mount-prefixed responses.
        expect(res['headers']).to have_key('kiosk-server-version')
      end

      it 'routes the RESERVED `pay` into WireController (401 problem, not 404)' do
        res = probe('mounted', 'POST /kiosk/pay')
        expect(res['status']).to eq(401)
        expect(res['headers']['content-type']).to include('application/problem+json')
        expect(JSON.parse(res['body'])['code']).to eq('unauthenticated')
      end

      # `GET /kiosk/schema` is public — routed into the same controller,
      # resolving no identity — so it answers a 200 CATALOG, not a 401.
      it 'routes the RESERVED `schema` into WireController and answers it PUBLIC' do
        res = probe('mounted', 'GET /kiosk/schema')
        expect(res['status']).to eq(200)
        expect(res['headers']['cache-control']).to eq('max-age=60, public')
        expect(res['headers']['etag']).to match(/\A"[0-9a-f]{32}"\z/)
        # A public document must not vary on headers it does not read.
        expect(res['headers']).not_to have_key('vary')
        body = JSON.parse(res['body'])
        expect(body.keys).to eq(%w[queries actions events])
        expect(body['queries']).not_to be_empty
      end

      it 'has no 0.3 multiplexed wire left: /query and /run name no route at all' do
        # Dialed WITH a Bearer token, so the identity gate cannot be what produced
        # the answer. Nothing draws these paths, so the answer is the host
        # framework's ordinary 404 with no Kiosk body.
        ['POST /kiosk/query (bearer)', 'POST /kiosk/run (bearer)'].each do |request_line|
          res = probe('mounted', request_line)
          expect(res['status']).to eq(404), "#{request_line}: got #{res['status']}"
          expect(res['headers']['content-type']).not_to include('application/problem+json')
          expect(res['body']).not_to include('verb_not_found')
        end
      end

      it 'does not serve a verb it registered but drew no route for' do
        # The sharpest statement of what the mount is. This scenario draws the
        # mount and NOTHING ELSE, so `ping` — a query this origin really does
        # register, published in the catalogue two examples up — has no route.
        # Declaring a verb publishes it in the catalogue; it does not put it on
        # the network. Nothing matches the path, so the answer is the host
        # framework's ordinary 404.
        res = probe('mounted', 'GET /kiosk/ping (bearer)')

        expect(res['status']).to eq(404)
        expect(res['headers']['content-type']).not_to include('application/problem+json')
      end

      it 'routes the kiosk-pop auth plane into AuthController' do
        # A malformed register/login/revoke answers with the wire's RFC 9457
        # problem document — reaching the controller at all is what this route
        # proof needs, and a top-level `code` is what says a Kiosk controller
        # answered rather than the router.
        %w[register login revoke].each do |action|
          res = probe('mounted', "POST /kiosk/auth/#{action}")
          expect(res['status']).to be_between(400, 401), "#{action}: got #{res['status']}"
          expect(JSON.parse(res['body'])).to have_key('code')
        end
        res = probe('mounted', 'GET /kiosk/auth/challenge')
        expect(res['status']).to eq(400)
        expect(JSON.parse(res['body'])).to have_key('code')
      end

      it 'routes the KYC attestation endpoint' do
        res = probe('mounted', 'POST /kiosk/agents/kyc')
        expect(res['status']).to eq(401)
        expect(JSON.parse(res['body'])['code']).to eq('unauthenticated')
      end

      it 'routes the binding ceremony: claim wire + link surface + HTML pages' do
        res = probe('mounted', 'POST /kiosk/oauth/device_authorization')
        expect(res['status']).to eq(400)
        expect(JSON.parse(res['body'])).to have_key('error')

        expect(probe('mounted', 'POST /kiosk/oauth/token')['status']).to eq(400)

        # No signed-in human; the two HTML pages demand one.
        expect(probe('mounted', 'GET /kiosk/oauth/device/verify')['status']).to eq(401)
        expect(probe('mounted', 'GET /kiosk/auth/assistants')['status']).to eq(401)

        %w[link claim unlink].each do |action|
          res = probe('mounted', "POST /kiosk/auth/#{action}")
          expect(res['status']).to be_between(400, 401), "#{action}: got #{res['status']}"
          # The Kiosk-native half of the ceremony answers the 0.4 problem
          # document (top-level `code`); the OAuth endpoints above keep the
          # RFC 8628 `{error, error_description}` shape, which is why only they
          # are asserted with `error`.
          expect(JSON.parse(res['body'])).to have_key('code')
        end

        # The page's own forms post to these three; the engine must route them
        # all.
        %w[link update unlink].each do |action|
          res = probe('mounted', "POST /kiosk/auth/assistants/#{action}")
          expect(res['status']).to eq(401), "assistants/#{action}: got #{res['status']}"
        end
      end
    end

    context 'when the engine is NOT mounted' do
      it 'installs no root discovery routes — loading the gem is inert' do
        expect(probe('unmounted', 'GET /agents.txt')['status']).to eq(404)
        expect(probe('unmounted', 'GET /.well-known/kiosk.json')['status']).to eq(404)
      end

      it 'serves no wire routes' do
        expect(probe('unmounted', 'GET /kiosk/schema')['status']).to eq(404)
      end

      it 'reports itself unmounted' do
        expect(probe('unmounted', 'mounted_in?')).to be(false)
      end
    end

    context 'when a host route is drawn ABOVE the mount at a path the engine draws' do
      it "the host's ROOT route wins: config/routes.rb precedes routes.append" do
        res = probe('double_draw', 'GET /agents.txt')
        expect(res['status']).to eq(200)
        expect(res['body']).to eq('HAND-DRAWN')
      end

      it "the host's MOUNT-PREFIXED route wins when drawn before the mount" do
        res = probe('double_draw', 'GET /kiosk/schema')
        expect(res['status']).to eq(200)
        expect(res['body']).to eq('HAND-DRAWN')
      end

      it 'paths only the engine draws still resolve through the mount' do
        res = probe('double_draw', 'GET /agents.json')
        expect(res['status']).to eq(200)
        expect(JSON.parse(res['body']).dig('site', 'url')).to eq('http://localhost')

        expect(probe('double_draw', 'GET /kiosk/.well-known/jwks.json')['status']).to eq(200)
      end
    end

    context 'when the host draws its own verbs with the `kiosk` block' do
      it 'a declared query reaches the VERB wire' do
        # `?zzz=1` against a CLOSED empty input_schema is `400 bad_request` from
        # RequestValidation — a gate only VerbController runs, and only after a
        # route has dispatched into it, so a 400 can have come from nowhere else.
        res = probe('operator_verbs', 'GET /kiosk/ping?zzz=1')

        expect(res['status']).to eq(400)
        expect(JSON.parse(res['body'])['code']).to eq('bad_request')
      end

      it 'answers the OTHER method on that same verb an ordinary routing 404' do
        # `ping` is declared a query, so its route is the GET; nothing draws POST /kiosk/ping,
        # so Rails matches nothing. The engine draws no route of its own under the
        # mount beyond the protocol plane, so there is no Kiosk document here: an
        # assistant reads the catalogue, which says `ping` is a query, and dials
        # the method the kind requires.
        res = probe('operator_verbs', 'POST /kiosk/ping')

        expect(res['status']).to eq(404)
        expect(res['headers']['allow']).to be_nil
        expect(res['headers']['content-type']).not_to include('application/problem+json')
      end

      it 'answers a name nobody registered the same ordinary 404' do
        # A name nobody registered has no route by construction, so it is
        # indistinguishable at the routing layer from a path that could never BE a
        # verb name. All three are dialed WITH a token, so the 401 gate cannot
        # be what produced the answer.
        ['GET /kiosk/frobnicate', 'GET /kiosk/Catalog', 'GET /kiosk/9lives'].each do |line|
          res = probe('operator_verbs', line)
          expect(res['status']).to eq(404), "#{line}: got #{res['status']}"
          expect(res['headers']['content-type']).not_to include('application/problem+json')
          expect(res['body']).not_to include('verb_not_found')
        end
      end

      # ── THE SHADOWING QUESTION, ANSWERED BY MEASUREMENT ──────────────────
      #
      # "What happens if an operator routes a verb at a reserved path?"
      #
      #   1. {HandlerMixin::RESERVED_NAMES} raises an ArgumentError as the class
      #      body loads, so the verb cannot be DECLARED (handler_mixin_spec).
      #   2. And if that were bypassed, `kiosk` draws the mount FIRST and Rails
      #      dispatches the first matching route — which is what this example
      #      measures. The scenario names `schema` in the block; the engine's
      #      `schema` answers and that route is dead.
      #
      # A collision is a DEAD ROUTE, silent on its own, which is why neither of
      # the two is optional.
      it 'cannot be shadowed by an operator verb route drawn below the mount' do
        res = probe('operator_verbs', 'GET /kiosk/schema')

        expect(res['status']).to eq(200)
        expect(res['headers']['content-type']).to include('application/json')
        # The WIRE's catalogue, not the verb wire's answer for a verb called
        # `schema` (which is 401 anonymous, and could never be registered anyway).
        expect(JSON.parse(res['body']).keys).to eq(%w[queries actions events])
      end
    end

    describe 'the three version headers, over the whole mounted surface (§3 point 6)' do
      it 'stamps every path UNDER the mount — success and refusal alike' do
        under_mount = probe('mounted').select { |line, _| line.start_with?('GET /kiosk', 'POST /kiosk') }
        expect(under_mount.size).to be >= 18 # the drawn surface, not a sample

        under_mount.each do |line, res|
          expect(res['headers'].keys & three_headers)
            .to match_array(three_headers), "#{line} answered #{res['status']} without all three headers"
        end
      end

      it 'leaves the ROOT-served discovery documents bare — they are outside the mount' do
        outside = probe('mounted').select do |line, res|
          res.is_a?(Hash) && !line.start_with?('GET /kiosk', 'POST /kiosk')
        end
        expect(outside.keys).to include('GET /agents.txt', 'GET /.well-known/kiosk.json')

        outside.each do |line, res|
          expect(res['headers'].keys & three_headers)
            .to be_empty, "#{line} carried a mount-only version header"
        end
      end
    end

    context 'when Rails composes the response itself (§3.6, K-824)' do
      it 'a routing 404 UNDER the mount carries all three' do
        res = probe('exceptions', 'GET /kiosk/nope/nope')
        expect(res['status']).to eq(404)
        expect(header_names('exceptions', 'GET /kiosk/nope/nope')).to match_array(three_headers)
      end

      it 'an unhandled 500 UNDER the mount carries all three' do
        # Raised by a deliberately broken agent-IdP adapter inside
        # WireController, whose `rescue_from` covers Errors::Base only — so it
        # unwinds past every Kiosk seam and Rails renders it.
        res = probe('exceptions', 'POST /kiosk/pay')
        expect(res['status']).to eq(500)
        expect(header_names('exceptions', 'POST /kiosk/pay')).to match_array(three_headers)
      end

      it "the HOST's own route outside the mount carries none — on a 200" do
        res = probe('exceptions', 'GET /outside')
        expect(res['status']).to eq(200)
        expect(res['body']).to eq('HAND-DRAWN')
        expect(header_names('exceptions', 'GET /outside')).to be_empty
      end

      it "…and none on the host's own 500, which is the same exception path" do
        res = probe('exceptions', 'GET /outside/boom')
        expect(res['status']).to eq(500)
        expect(header_names('exceptions', 'GET /outside/boom')).to be_empty
      end

      it '…and none on a root-level routing 404' do
        res = probe('exceptions', 'GET /nope')
        expect(res['status']).to eq(404)
        expect(header_names('exceptions', 'GET /nope')).to be_empty
      end
    end

    context 'when the origin declines the account-binding module (§16.1 item 7)' do
      EngineMountSpec::DECLINED_PATHS.each do |line|
        it "answers #{line} with a 501 module_not_served problem document" do
          res = probe('binding_declined', line)
          expect(res['status']).to eq(501)
          expect(res['headers']['content-type']).to include('application/problem+json')

          problem = JSON.parse(res['body'])
          expect(problem['code']).to   eq('module_not_served')
          expect(problem['status']).to eq(501)
          expect(problem['detail']).to include('account binding')
        end
      end

      it 'still serves the core: schema answers, and auth/challenge is the CORE refusal' do
        expect(probe('binding_declined', 'GET /kiosk/schema')['status']).to eq(200)

        challenge = probe('binding_declined', 'GET /kiosk/auth/challenge')
        expect(challenge['status']).to eq(400)
        expect(JSON.parse(challenge['body'])['code']).to eq('bad_request')
      end

      # §4.3: the auth block is core discovery, so nothing about the declined
      # module is visible before a caller dials it.
      it 'publishes all six auth URLs and no binding capability' do
        res = probe('binding_declined', 'GET /.well-known/kiosk.json')
        expect(res['status']).to eq(200)

        kiosk = JSON.parse(res['body']).fetch('kiosk')
        expect(kiosk.fetch('auth').keys).to include(
          'challenge_url', 'register_url', 'login_url', 'revoke_url',
          'device_authorization_url', 'claim_url'
        )
        expect(kiosk.fetch('capabilities')).to include('queries')
        expect(kiosk.fetch('capabilities').grep(/bind/)).to be_empty
      end
    end

    context 'when a second origin is served' do
      it 'advertises each origin as its own issuer' do
        expect(issuer_on('localhost kiosk.json')).to eq('http://localhost')
        expect(issuer_on('buymilk kiosk.json')).to eq('http://buymilk.example')
      end

      it 'accepts a token only on the origin that minted it' do
        expect(probe('two_origins', 'buymilk token on buymilk')['status']).to eq(400)
        expect(probe('two_origins', 'buymilk token on localhost')['status']).to eq(401)
        expect(probe('two_origins', 'localhost token on buymilk')['status']).to eq(401)
      end
    end
  end
end
