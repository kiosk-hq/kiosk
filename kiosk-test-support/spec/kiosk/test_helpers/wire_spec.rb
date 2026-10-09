# frozen_string_literal: true

require "base64"
require "kiosk/test_helpers/wire"

RSpec.describe Kiosk::TestHelpers::Wire do
  subject(:wire) { described_class.new(base_url: "http://provider.test/") }

  it "builds a bearer header" do
    expect(described_class.bearer("tok")).to eq("Authorization" => "Bearer tok")
    expect(wire.bearer("tok")).to eq("Authorization" => "Bearer tok")
  end

  it "posts JSON with the caller's headers and answers the status and the parsed body" do
    stub_request(:post, "http://provider.test/kiosk/edit_listing")
      .with(body: { listing_id: "junk" }.to_json, headers: { "Content-Type" => "application/json", "Authorization" => "Bearer tok" })
      .to_return(problem_return("bad_request"))

    status, problem = wire.post_json("/kiosk/edit_listing", { listing_id: "junk" }, wire.bearer("tok"))

    expect([status, problem["code"]]).to eq([400, "bad_request"])
  end

  it "puts params on the query string, and sends a bare GET without a content type" do
    stub_request(:get, "http://provider.test/kiosk/browse").with(query: { "keyword" => "bike" })
                                                         .with { !_1.headers.key?("Content-Type") }
                                                         .to_return(json_return(200, []))
    stub_request(:get, "http://provider.test/kiosk/browse").to_return(json_return(401, {}))

    expect(wire.get_json("/kiosk/browse", keyword: "bike")).to eq([200, []])
    expect(wire.get_json("/kiosk/browse").first).to eq(401)
  end

  it "answers the headers, case-insensitively" do
    stub_request(:get, "http://provider.test/kiosk/post_listing")
      .to_return(status: 405, body: "{}", headers: { "Allow" => "POST" })

    response = wire.request(:get, "/kiosk/post_listing")

    expect([response.status, response["allow"], response["Allow"]]).to eq([405, "POST", "POST"])
  end

  it "reads a body that is not JSON as an empty hash and keeps its bytes" do
    stub_request(:get, "http://provider.test/kiosk/x").to_return(status: 500, body: "PG::InvalidTextRepresentation")

    response = wire.get("/kiosk/x")

    expect([response.status, response.body, response.raw_body]).to eq([500, {}, "PG::InvalidTextRepresentation"])
  end

  it "answers status 0 for an origin it cannot reach" do
    stub_request(:get, "http://provider.test/kiosk/x").to_timeout

    expect(wire.get("/kiosk/x")).to have_attributes(status: 0, body: include("error"))
  end

  it "posts a form" do
    stub_request(:post, "http://provider.test/oauth").with(body: { "client_id" => "cli" })
                                                     .to_return(json_return(200, "ok" => true))

    expect(wire.post_form("/oauth", "client_id" => "cli").body).to eq("ok" => true)
  end

  it "pays a proof-of-work toll only when told to" do
    toll = { "id" => "c1", "alg" => "equihash", "params" => { "n" => 8, "k" => 1 },
             "salt" => Base64.strict_encode64("kat"), "exp" => 9_999_999_999, "sig" => "x" }
    stub_request(:get, "http://provider.test/kiosk/catalog")
      .to_return(problem_return("pow_required", status: 402, challenges: [toll]))
    stub_request(:get, "http://provider.test/kiosk/catalog").with(headers: { "Kiosk-PoW" => /indices/ })
                                                           .to_return(json_return(200, []))

    expect(wire.get("/kiosk/catalog")).to have_attributes(status: 402, proofs: 0)
    expect(described_class.new(base_url: "http://provider.test", pay_tolls: true).get("/kiosk/catalog"))
      .to have_attributes(status: 200, proofs: 1)
  end

  it "refuses a method it cannot spell" do
    expect { wire.request(:teleport, "/kiosk/x") }.to raise_error(ArgumentError, /teleport/)
  end

  describe ".http_for" do
    it "dials TLS exactly when the scheme says https" do
      expect(described_class.http_for(URI("https://provider.test:8443/x"))).to have_attributes(use_ssl?: true, port: 8443)
      expect(described_class.http_for(URI("http://provider.test:3001/x"))).to have_attributes(use_ssl?: false, port: 3001)
    end

    it "sets timeouts only when asked" do
      expect(described_class.http_for(URI("https://provider.test"))).to have_attributes(open_timeout: 60, read_timeout: 60)
      expect(described_class.http_for(URI("https://provider.test"), open_timeout: 3, read_timeout: 7))
        .to have_attributes(open_timeout: 3, read_timeout: 7)
    end

    it "reaches an https origin over TLS" do
      stub_request(:get, "https://provider.test/kiosk/schema").to_return(json_return(200, "queries" => []))

      expect(described_class.new(base_url: "https://provider.test").get_json("/kiosk/schema")).to eq([200, { "queries" => [] }])
    end
  end
end
