# frozen_string_literal: true

require "rack/mock"

RSpec.describe Kiosk::Server::HeadersMiddleware do
  let(:downstream_app) do
    ->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] }
  end

  subject(:middleware) { described_class.new(downstream_app) }

  def call(path)
    env = Rack::MockRequest.env_for(path)
    middleware.call(env)
  end

  describe "kiosk paths" do
    it "injects the three Kiosk headers on /kiosk root" do
      _, headers, _ = call("/kiosk")
      expect(headers[Kiosk::Protocol::HEADER_SERVER_VERSION]).to eq(Kiosk::Server::VERSION)
      expect(headers[Kiosk::Protocol::HEADER_API_VERSION]).to    eq(Kiosk::Protocol::API_VERSION)
      expect(headers[Kiosk::Protocol::HEADER_MIN_CLIENT]).to     eq(Kiosk::Protocol::MIN_CLIENT)
    end

    it "injects the headers on any /kiosk/* sub-path" do
      _, headers, _ = call("/kiosk/exec")
      expect(headers[Kiosk::Protocol::HEADER_API_VERSION]).to eq(Kiosk::Protocol::API_VERSION)
    end

    it "respects an overridden mount_path" do
      Kiosk.configure { |c| c.mount_path = "/agent-surface" }
      _, headers, _ = call("/agent-surface/exec")
      expect(headers[Kiosk::Protocol::HEADER_API_VERSION]).to eq(Kiosk::Protocol::API_VERSION)
    end
  end

  describe "non-kiosk paths" do
    it "passes downstream headers through unchanged on /unrelated" do
      _, headers, _ = call("/unrelated")
      expect(headers).not_to have_key(Kiosk::Protocol::HEADER_API_VERSION)
      expect(headers["Content-Type"]).to eq("text/plain")
    end

    it "does NOT match a path that merely shares the mount-path prefix as a substring" do
      # /kiosk-news should not be treated as /kiosk + /news
      _, headers, _ = call("/kiosk-news")
      expect(headers).not_to have_key(Kiosk::Protocol::HEADER_API_VERSION)
    end
  end
end
