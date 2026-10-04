# frozen_string_literal: true

RSpec.describe "Kiosk.current_issuer" do
  describe "Configuration#additional_origins" do
    it "defaults to an empty list" do
      expect(Kiosk::Configuration.new.additional_origins).to eq([])
    end
  end

  describe "Configuration#origins" do
    subject(:config) { Kiosk::Configuration.new }

    it "is the issuer alone when nothing else is listed" do
      config.issuer = "https://getgrocery.example"
      expect(config.origins).to eq(["https://getgrocery.example"])
    end

    it "is empty while no issuer is set" do
      expect(config.origins).to eq([])
    end

    it "normalises scheme, host, trailing slash and default port" do
      config.issuer = "HTTPS://GetGrocery.Example:443/"
      config.additional_origins = ["http://BuyMilk.example:80", "http://localhost:3001/"]
      expect(config.origins).to eq(%w[https://getgrocery.example http://buymilk.example http://localhost:3001])
    end

    it "lists each origin once" do
      config.issuer = "https://a.example"
      config.additional_origins = ["https://A.example/"]
      expect(config.origins).to eq(["https://a.example"])
    end
  end

  describe "Configuration#issuer_for" do
    subject(:config) { Kiosk::Configuration.new }

    before do
      config.issuer = "https://a.example"
      config.additional_origins = ["https://b.example"]
    end

    it "answers a listed origin, normalised" do
      expect(config.issuer_for("HTTPS://B.example:443")).to eq("https://b.example")
    end

    it "answers the issuer for an origin the operator does not serve" do
      expect(config.issuer_for("http://www.example.com")).to eq("https://a.example")
    end

    it "answers the issuer for a value that is not an origin" do
      expect(config.issuer_for("not a url")).to eq("https://a.example")
    end
  end

  describe "Kiosk.with_issuer" do
    before { Kiosk.configure { |c| c.issuer = "https://a.example" } }

    it "falls back to the configured issuer outside a block" do
      expect(Kiosk.current_issuer).to eq("https://a.example")
    end

    it "answers the block's issuer inside it" do
      seen = Kiosk.with_issuer("https://b.example") { Kiosk.current_issuer }
      expect(seen).to eq("https://b.example")
    end

    it "restores the previous issuer after a raise" do
      expect { Kiosk.with_issuer("https://b.example") { raise "boom" } }.to raise_error("boom")
      expect(Kiosk.current_issuer).to eq("https://a.example")
    end

    it "restores the outer issuer after a nested block" do
      inner = nil
      outer = Kiosk.with_issuer("https://b.example") do
        inner = Kiosk.with_issuer("https://c.example") { Kiosk.current_issuer }
        Kiosk.current_issuer
      end
      expect([inner, outer]).to eq(%w[https://c.example https://b.example])
    end
  end
end
