# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::Redteam::Wire do
  subject(:wire) { described_class.new(base_url: "http://provider.test") }

  describe ".bearer" do
    it "builds the Authorization header a forged token is sent under" do
      expect(described_class.bearer("tok")).to eq("Authorization" => "Bearer tok")
    end

    it "is available on an instance for a token the origin minted" do
      expect(wire.bearer("tok")).to eq("Authorization" => "Bearer tok")
    end
  end

  describe "#post_json" do
    it "answers the status and the parsed problem document" do
      stub_request(:post, "http://provider.test/kiosk/edit_listing")
        .with(body: { listing_id: "junk" }.to_json,
              headers: { "Content-Type" => "application/json" })
        .to_return(problem_return("bad_request"))

      status, doc = wire.post_json("/kiosk/edit_listing", { listing_id: "junk" })

      expect(status).to eq(400)
      expect(doc["code"]).to eq("bad_request")
    end

    it "sends the caller's headers alongside the JSON content type" do
      stub_request(:post, "http://provider.test/kiosk/post_listing")
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(json_return(200, "listing_id" => "L1"))

      status, doc = wire.post_json("/kiosk/post_listing", {}, wire.bearer("tok"))

      expect([status, doc]).to eq([200, { "listing_id" => "L1" }])
    end
  end

  describe "#get_json" do
    it "form-encodes params onto the query string" do
      stub_request(:get, "http://provider.test/kiosk/browse_listings")
        .with(query: { "keyword" => "b_ke" })
        .to_return(json_return(200, []))

      status, doc = wire.get_json("/kiosk/browse_listings", { keyword: "b_ke" })

      expect([status, doc]).to eq([200, []])
    end

    it "omits the query string entirely when there are no params" do
      stub_request(:get, "http://provider.test/kiosk/browse_listings")
        .to_return(json_return(401, {}))

      expect(wire.get_json("/kiosk/browse_listings").first).to eq(401)
    end
  end

  describe "a body that is not JSON" do
    # An attack that provokes an HTML error page has to be ASSERTED on. A
    # harness that raised here would report nothing about the answer it came
    # for, and the operator would read a crash where a verdict belongs.
    it "reads as an empty hash while the status still carries the verdict" do
      stub_request(:get, "http://provider.test/kiosk/anything")
        .to_return(status: 502, body: "<html>bad gateway</html>",
                   headers: { "Content-Type" => "text/html" })

      status, doc = wire.get_json("/kiosk/anything")

      expect([status, doc]).to eq([502, {}])
    end

    it "still exposes the bytes exactly as they arrived, for a leak scan" do
      stub_request(:get, "http://provider.test/kiosk/anything")
        .to_return(status: 500, body: "PG::InvalidTextRepresentation: 22P02")

      raw = wire.get("/kiosk/anything")

      expect(raw.raw_body).to include("22P02")
      expect(raw.body).to eq({})
    end
  end

  describe "a connection error" do
    # 0 is outside every status a scenario admits and Kiosk::Redteam.blocked?
    # answers false for it by name, so an unreachable origin can never read as
    # a refusal.
    it "answers status 0 rather than raising" do
      stub_request(:get, "http://provider.test/kiosk/anything").to_timeout

      raw = wire.get("/kiosk/anything")

      expect(raw.status).to eq(0)
      expect(raw.body["error"]).to be_a(String)
    end

    it "is never blocked" do
      stub_request(:get, "http://provider.test/kiosk/anything").to_timeout
      raw = wire.get("/kiosk/anything")

      response = Kiosk::Redteam::Response.new(status: raw.status, body: raw.body)
      expect(Kiosk::Redteam.blocked?(response)).to be(false)
    end
  end

  describe "#request" do
    it "reaches a response header, which is what a method-mismatch beat asserts on" do
      stub_request(:get, "http://provider.test/kiosk/post_listing")
        .to_return(status: 405, body: JSON.generate(problem("method_not_allowed")),
                   headers: { "Allow" => "POST", "Content-Type" => PROBLEM_CONTENT_TYPE })

      raw = wire.request(:get, "/kiosk/post_listing")

      expect(raw.status).to eq(405)
      expect(raw["allow"]).to eq("POST")
      expect(raw["Allow"]).to eq("POST")
      expect(raw.body["code"]).to eq("method_not_allowed")
    end

    it "sends no content type when there is no body, so a bare GET is a bare GET" do
      stub_request(:get, "http://provider.test/kiosk/x")
        .with { |req| !req.headers.key?("Content-Type") }
        .to_return(json_return(200, {}))

      expect(wire.request(:get, "/kiosk/x").status).to eq(200)
    end

    it "refuses a method it cannot spell instead of failing somewhere deeper" do
      expect { wire.request(:teleport, "/kiosk/x") }
        .to raise_error(ArgumentError, /teleport/)
    end
  end

  it "tolerates a base_url with a trailing slash" do
    stub_request(:get, "http://provider.test/kiosk/x").to_return(json_return(200, {}))

    expect(described_class.new(base_url: "http://provider.test/").get_json("/kiosk/x").first)
      .to eq(200)
  end
end
