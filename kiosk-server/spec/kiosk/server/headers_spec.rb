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

    # K-747. The header and `kiosk.min_client` in /.well-known/kiosk.json are
    # two publications of ONE advisory number, and this one used to ignore the
    # setter and emit the constant — so an operator who bumped it got 0.5.0 in
    # the discovery document and 0.4.0 on every wire response, with nothing to
    # say which was authoritative. `well_known_spec.rb` pins the other half.
    it "publishes the operator's configured min_client, not the constant" do
      Kiosk.configure { |c| c.min_client = "0.5.0" }

      expect(described_class.add_to({})[Kiosk::Protocol::HEADER_MIN_CLIENT]).to eq("0.5.0")
      expect(described_class.add_to({})[Kiosk::Protocol::HEADER_MIN_CLIENT])
        .to eq(Kiosk.configuration.min_client)
    end

    it "falls back to the protocol constant when the operator sets nothing" do
      expect(described_class.add_to({})[Kiosk::Protocol::HEADER_MIN_CLIENT])
        .to eq(Kiosk::Protocol::MIN_CLIENT)
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

    # §3.7.3 (K-823). "Leaves an operator's own alone" stops at the one policy
    # the spec forbids: a verb payload is scoped to one authenticated identity,
    # so `public` or `s-maxage` hands it to a shared cache and thence to
    # another caller. Until a handler's headers could reach this seam at all
    # the prohibition held by accident; now it is a check.
    describe "and it REFUSES a shared-cache policy (§3.7.3)" do
      before { allow(Kiosk::Server::Headers).to receive(:warn) }

      [
        "public",
        "public, max-age=600",
        "PUBLIC",
        "s-maxage=600",
        "private, s-maxage=600",
        "max-age=600, public, immutable",
        # RFC 9111 §3.5's third door — a shared cache MAY reuse a response to
        # an `Authorization`-bearing request when it says `must-revalidate`,
        # and every verb request bears one. §3.7.3 NAMES ALL THREE since K-826
        # (see the note on SHARED_CACHE_DIRECTIVES in lib/), so this probe is
        # the third door's and the seam is exactly as strict as the text.
        "max-age=600, must-revalidate",
      ].each do |policy|
        it "replaces #{policy.inspect} with the wire's own default" do
          headers = described_class.add_cache_policy({ "Cache-Control" => policy }, status: 200)
          expect(headers["Cache-Control"]).to eq("private, no-store")
        end
      end

      it "REFUSES rather than EDITS: it does not keep the freshness and drop the word" do
        # `private, max-age=600` would be a policy nobody wrote — a guess that
        # a handler asking for a shared cache meant a private one of the same
        # length. Refusing says what happened; editing hides it.
        headers = described_class.add_cache_policy({ "Cache-Control" => "public, max-age=600" },
                                                   status: 200)
        expect(headers["Cache-Control"]).not_to include("600")
      end

      it "says so, once, naming the value it refused" do
        expect(Kiosk::Server::Headers).to receive(:warn)
          .with(a_string_including("public, max-age=600")).once
        described_class.add_cache_policy({ "Cache-Control" => "public, max-age=600" }, status: 200)
      end

      it "leaves a CONFORMANT relaxation alone — the control" do
        # Without this line "refuses shared caching" would pass just as well on
        # a build that refused every operator policy, which would delete
        # §3.7.4's MAY instead of enforcing §3.7.3.
        headers = described_class.add_cache_policy({ "Cache-Control" => "private, max-age=600" },
                                                   status: 200)
        expect(headers["Cache-Control"]).to eq("private, max-age=600")
      end
    end
  end
end
