# frozen_string_literal: true

require 'rack/mock'

RSpec.shared_context 'headers middleware spec: rack harness' do
  subject(:middleware) { described_class.new(downstream_app) }

  let(:downstream_app) do
    ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['ok']] }
  end

  def call(path)
    env = Rack::MockRequest.env_for(path)
    middleware.call(env)
  end
end

RSpec.describe Kiosk::Server::HeadersMiddleware, 'kiosk paths' do
  include_context 'headers middleware spec: rack harness'

  it 'injects the three Kiosk headers on /kiosk root' do
    _, headers, = call('/kiosk')
    expect(headers[Kiosk::Protocol::HEADER_SERVER_VERSION]).to eq(Kiosk::Server::VERSION)
    expect(headers[Kiosk::Protocol::HEADER_API_VERSION]).to    eq(Kiosk::Protocol::API_VERSION)
    expect(headers[Kiosk::Protocol::HEADER_MIN_CLIENT]).to     eq(Kiosk::Protocol::MIN_CLIENT)
  end

  it 'injects the headers on any /kiosk/* sub-path' do
    # Any path under the mount — the middleware matches on the PREFIX and
    # never consults the route table, which is the whole point: it stamps a
    # 404 from a mistyped verb as readily as a 200 from a real one.
    _, headers, = call('/kiosk/catalog')
    expect(headers[Kiosk::Protocol::HEADER_API_VERSION]).to eq(Kiosk::Protocol::API_VERSION)
  end

  it 'respects an overridden mount_path' do
    Kiosk.configure { |c| c.mount_path = '/agent-surface' }
    _, headers, = call('/agent-surface/exec')
    expect(headers[Kiosk::Protocol::HEADER_API_VERSION]).to eq(Kiosk::Protocol::API_VERSION)
  end
end

# K-824, the half the engine-mount probe found: the stamp must survive a
# downstream layer REWRITING the request path. Rails does exactly this —
# `ActionDispatch::ShowExceptions#render_exception` sets `PATH_INFO` to
# `/404` or `/500` before calling the exceptions app and never restores it —
# so a middleware that reads the path after the call sees a path nobody
# requested. This is the unit-level statement of the property; the booted
# proof is in engine_mount_spec.
RSpec.describe Kiosk::Server::HeadersMiddleware, "when a downstream layer rewrites PATH_INFO (Rails' exception apps)" do
  include_context 'headers middleware spec: rack harness'

  let(:downstream_app) do
    lambda do |env|
      env['PATH_INFO'] = '/500'
      [500, { 'Content-Type' => 'text/plain' }, ['boom']]
    end
  end

  it "still stamps: the request's identity was decided before the app ran" do
    _, headers, = call('/kiosk/salons')
    expect(headers[Kiosk::Protocol::HEADER_API_VERSION]).to eq(Kiosk::Protocol::API_VERSION)
  end

  context 'and the rewrite points INTO the mount path' do
    # The mirror: a non-Kiosk request whose path is rewritten to look like a
    # Kiosk one must stay bare, or the guard would be a coin toss rather than
    # a question about the caller.
    let(:downstream_app) do
      lambda do |env|
        env['PATH_INFO'] = '/kiosk/500'
        [500, { 'Content-Type' => 'text/plain' }, ['boom']]
      end
    end

    it 'does not earn a stamp' do
      _, headers, = call('/unrelated')
      expect(headers).not_to have_key(Kiosk::Protocol::HEADER_API_VERSION)
    end
  end
end

RSpec.describe Kiosk::Server::HeadersMiddleware, 'non-kiosk paths' do
  include_context 'headers middleware spec: rack harness'

  it 'passes downstream headers through unchanged on /unrelated' do
    _, headers, = call('/unrelated')
    expect(headers).not_to have_key(Kiosk::Protocol::HEADER_API_VERSION)
    expect(headers['Content-Type']).to eq('text/plain')
  end

  it 'does NOT match a path that merely shares the mount-path prefix as a substring' do
    # /kiosk-news should not be treated as /kiosk + /news
    _, headers, = call('/kiosk-news')
    expect(headers).not_to have_key(Kiosk::Protocol::HEADER_API_VERSION)
  end
end
