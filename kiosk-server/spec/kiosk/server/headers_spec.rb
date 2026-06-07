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
end
