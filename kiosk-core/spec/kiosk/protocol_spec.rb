# frozen_string_literal: true

RSpec.describe Kiosk::Protocol do
  it "exposes API_VERSION as a semver string" do
    expect(described_class::API_VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "exposes MIN_CLIENT as a semver string" do
    expect(described_class::MIN_CLIENT).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "names the three response headers Kiosk sends on /kiosk/* responses" do
    expect(described_class::HEADER_SERVER_VERSION).to eq("Kiosk-Server-Version")
    expect(described_class::HEADER_API_VERSION).to    eq("Kiosk-API-Version")
    expect(described_class::HEADER_MIN_CLIENT).to     eq("Kiosk-Min-Client")
  end

  it "documents the well-known discovery path" do
    expect(described_class::WELL_KNOWN_PATH).to eq("/.well-known/kiosk.json")
  end

  it "documents the default mount path" do
    expect(described_class::DEFAULT_MOUNT_PATH).to eq("/kiosk")
  end
end
