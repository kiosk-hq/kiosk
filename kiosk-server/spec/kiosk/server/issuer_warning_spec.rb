# frozen_string_literal: true

# The boot warning for an `issuer` that cannot be right.
#
# Two conditions and no third: UNSET is wrong in every environment, a LOOPBACK
# origin only outside development and test. The second half is what these
# examples mostly pin — `http://localhost:3000` is the correct issuer for every
# demo and for `rails server`, so a warning there would print on every local
# boot and the deployed one would stop being read.
#
# The condition is a class method rather than inline in the engine's
# `after_initialize` block so it can be asserted without booting an app; the
# block is three lines that call it.
RSpec.describe Kiosk::Server::Engine, ".issuer_warning" do
  def warning(local: false)
    described_class.issuer_warning(config: Kiosk.configuration, local: local)
  end

  context "when `issuer` is unset" do
    it "warns even in development, where the loopback half stays quiet" do
      expect(Kiosk.configuration.issuer).to be_nil
      expect(warning(local: true)).to include("`c.issuer` is not set")
    end

    it "names the refusal the operator will see, and the line that fixes it" do
      expect(warning).to include("proof audience mismatch")
      expect(warning).to include(%(c.issuer = "https://api.example.com"))
    end

    it "reads whitespace as unset" do
      Kiosk.configure { |c| c.issuer = "   " }
      expect(warning).to include("`c.issuer` is not set")
    end
  end

  context "when `issuer` is a loopback origin" do
    before { Kiosk.configure { |c| c.issuer = "http://localhost:3000" } }

    it "stays quiet in development and test, where it is the correct value" do
      expect(warning(local: true)).to be_nil
    end

    it "warns outside them" do
      expect(warning).to include("No assistant can reach a loopback origin")
    end

    it "says to redirect alias hostnames instead of serving both" do
      expect(warning).to include("One instance serves exactly one origin")
    end

    ["http://127.0.0.1:3000", "https://localhost", "0.0.0.0:3000", "http://[::1]:9292"].each do |issuer|
      it "recognises #{issuer}" do
        Kiosk.configure { |c| c.issuer = issuer }
        expect(warning).to include("loopback origin")
      end
    end
  end

  it "stays quiet on a public origin, in every environment" do
    Kiosk.configure { |c| c.issuer = "https://api.example.com" }
    expect(warning).to be_nil
    expect(warning(local: true)).to be_nil
  end

  it "does not read a routable host that merely starts with a loopback name as loopback" do
    Kiosk.configure { |c| c.issuer = "https://localhost.example.com" }
    expect(warning).to be_nil
  end
end
