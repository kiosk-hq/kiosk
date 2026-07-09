# frozen_string_literal: true

RSpec.describe "kiosk-all meta-gem" do
  it "defines its own version constant" do
    expect(Kiosk::All::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  describe "loads the production data-plane gems" do
    it "loads kiosk-core (defines Kiosk and Kiosk::VERSION)" do
      expect(defined?(Kiosk)).to eq("constant")
      expect(Kiosk::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
    end

    it "loads kiosk-server (defines Kiosk::Server and Kiosk::Server::VERSION)" do
      expect(defined?(Kiosk::Server)).to eq("constant")
      expect(Kiosk::Server::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
    end
  end

  describe "deliberately does not pull in test-only or adapter gems" do
    # Smoke check: these modules belong to gems kiosk-all does *not* depend on.
    # If they ever load via kiosk-all, the runtime dependency boundary has leaked.

    it "does not load kiosk-rls (RLS is opt-in; host adds the gem explicitly)" do
      expect(defined?(Kiosk::RLS)).to be_nil
    end
  end
end
