# frozen_string_literal: true

RSpec.describe Kiosk::Server::Headers do
  describe ".add_to" do
    it "mutates a Rack headers hash with the three Kiosk headers" do
      headers = { "Content-Type" => "application/json" }
      result = described_class.add_to(headers)

      expect(result["Content-Type"]).to                                eq("application/json")
      expect(result[Kiosk::Protocol::HEADER_SERVER_VERSION]).to        eq(Kiosk::Server::VERSION)
      expect(result[Kiosk::Protocol::HEADER_API_VERSION]).to           eq(Kiosk::Protocol::API_VERSION)
      expect(result[Kiosk::Protocol::HEADER_MIN_CLIENT]).to            eq(Kiosk::Protocol::MIN_CLIENT)
    end

    it "accepts an overridden server_version (useful for tests)" do
      headers = described_class.add_to({}, server_version: "9.9.9")
      expect(headers[Kiosk::Protocol::HEADER_SERVER_VERSION]).to eq("9.9.9")
    end

    it "returns the same headers hash it was given (mutation contract)" do
      headers = {}
      expect(described_class.add_to(headers)).to equal(headers)
    end
  end

  describe ".build" do
    it "produces a fresh headers hash with the three Kiosk headers set" do
      headers = described_class.build
      expect(headers.keys).to contain_exactly(
        Kiosk::Protocol::HEADER_SERVER_VERSION,
        Kiosk::Protocol::HEADER_API_VERSION,
        Kiosk::Protocol::HEADER_MIN_CLIENT,
      )
    end
  end

  # Design §3.3, landed with the response shape (T-068 slice 2). Not in
  # HeadersMiddleware on purpose: that covers every path under the mount,
  # including the deliberately public, long-lived `/kiosk/.well-known/
  # jwks.json`, where `Vary: Authorization` would be both a lie and a
  # performance regression.
  describe ".add_cache_policy" do
    it "varies on the two request headers that change the answer" do
      headers = described_class.add_cache_policy({}, status: 200)
      expect(headers["Vary"]).to eq("Authorization, Kiosk-PoW")
    end

    it "ADDS to a Vary the operator already set rather than replacing it" do
      headers = described_class.add_cache_policy({ "Vary" => "Accept-Language" }, status: 200)
      expect(headers["Vary"]).to eq("Accept-Language, Authorization, Kiosk-PoW")
    end

    it "does not duplicate a token already present, whatever its case" do
      headers = described_class.add_cache_policy({ "Vary" => "authorization" }, status: 200)
      expect(headers["Vary"]).to eq("authorization, Kiosk-PoW")
    end

    it "defaults a 200 to private, no-store" do
      expect(described_class.add_cache_policy({}, status: 200)["Cache-Control"])
        .to eq("private, no-store")
    end

    it "leaves an operator's own Cache-Control alone — that is how a toll gets cached away" do
      headers = described_class.add_cache_policy({ "Cache-Control" => "private, max-age=60" },
                                                 status: 200)
      expect(headers["Cache-Control"]).to eq("private, max-age=60")
    end

    it "FORCES no-store on a 402 — a single-use challenge is never cacheable" do
      headers = described_class.add_cache_policy({ "Cache-Control" => "private, max-age=60" },
                                                 status: 402)
      expect(headers["Cache-Control"]).to eq("no-store")
    end
  end
end
