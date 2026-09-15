# frozen_string_literal: true

require "spec_helper"

# THE ONE THING EVERY DRIVER IN THIS REPOSITORY NEEDS AND ONLY THIS GEM HAS:
# a socket whose TLS is decided by the target's own scheme.
#
# These examples are behavioural on purpose. A unit assertion that
# `http.use_ssl?` is true proves the attribute was set; it does not prove the
# bytes left over TLS, and the defect this file exists to keep out was exactly
# that gap — `Client` built a `Net::HTTP` and never touched the attribute, so
# an `https://` base URL was dialled in cleartext on port 443 and the edge reset
# the connection. WebMock builds its request signature from `Net::HTTP#use_ssl?`,
# so a stub registered on `https://…` matches ONLY when the socket really is a
# TLS one: remove the seam's assignment and every example below goes red with an
# unstubbed `http://provider.test:443/…`.
RSpec.describe "the TLS seam" do
  HTTPS = "https://provider.test"
  HTTP  = "http://provider.test"

  describe "Kiosk::Redteam::Wire.http_for" do
    it "dials TLS when the target says https" do
      http = Kiosk::Redteam::Wire.http_for(URI("#{HTTPS}/kiosk/schema"))

      expect([http.use_ssl?, http.address, http.port]).to eq([true, "provider.test", 443])
    end

    it "does not dial TLS when the target says http" do
      http = Kiosk::Redteam::Wire.http_for(URI("#{HTTP}:3001/kiosk/schema"))

      expect([http.use_ssl?, http.port]).to eq([false, 3001])
    end

    it "reads the scheme and nothing else — an https URL on a non-443 port is still TLS" do
      http = Kiosk::Redteam::Wire.http_for(URI("#{HTTPS}:8443/kiosk/schema"))

      expect([http.use_ssl?, http.port]).to eq([true, 8443])
    end

    # The seam returns a configured socket factory, not a timeout policy: a
    # driver that never set one keeps the behaviour it had. 60/60 is Net::HTTP's
    # own default for both, so this example also says loudly if that moves.
    it "leaves Net::HTTP's own timeouts alone unless asked" do
      default = Kiosk::Redteam::Wire.http_for(URI(HTTPS))
      tuned   = Kiosk::Redteam::Wire.http_for(URI(HTTPS), open_timeout: 3, read_timeout: 7)

      expect([default.open_timeout, default.read_timeout]).to eq([60, 60])
      expect([tuned.open_timeout, tuned.read_timeout]).to eq([3, 7])
    end
  end

  describe Kiosk::Redteam::Wire do
    it "reaches an https origin" do
      stub_request(:get, "#{HTTPS}/kiosk/schema").to_return(json_return(200, "queries" => []))

      status, doc = described_class.new(base_url: HTTPS).get_json("/kiosk/schema")

      expect([status, doc]).to eq([200, { "queries" => [] }])
    end
  end

  # THE K-1622 REPRODUCTION. `Client` is what `Runner` builds and what the
  # gem's README points an adopter at, so these four are the published
  # portability claim expressed as assertions.
  describe Kiosk::Redteam::Client do
    subject(:client) { described_class.new(base_url: HTTPS) }

    it "registers against an https origin" do
      stub_request(:get, %r{\Ahttps://provider\.test/kiosk/auth/challenge})
        .to_return(json_return(200, "challenge" => "nonce", "exp" => Time.now.to_i + 120))
      stub_request(:post, "#{HTTPS}/kiosk/auth/register")
        .to_return(json_return(201, "agent_id" => "a1", "user_id" => "u1",
                                    "access_token" => "tok"))

      expect(client.register_raw(name: "probe", pow: :skip).status).to eq(201)
      expect(a_request(:post, "#{HTTPS}/kiosk/auth/register")).to have_been_made
    end

    it "queries an https origin" do
      stub_request(:get, "#{HTTPS}/kiosk/properties?city=Izmir")
        .to_return(json_return(200, [{ "id" => "p1" }]))

      principal = Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1",
                                                token: "tok", rsa_key: nil)

      expect(client.query(principal, name: "properties", city: "Izmir").status).to eq(200)
    end

    it "runs an action against an https origin" do
      stub_request(:post, "#{HTTPS}/kiosk/book_room").to_return(json_return(200, "ok" => true))

      principal = Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1",
                                                token: "tok", rsa_key: nil)

      expect(client.run(principal, name: "book_room", room: "r1").status).to eq(200)
    end

    # post_form is its own call site — the OAuth half of the binding ceremony
    # is form-encoded and therefore does not travel through #post_json.
    it "opens the device-grant ceremony against an https origin" do
      stub_request(:post, "#{HTTPS}/kiosk/oauth/device_authorization")
        .to_return(json_return(200, "device_code" => "d1", "user_code" => "ABCD"))

      response = client.device_authorization(client_id: "cli", public_key: "PEM")

      expect(response.body["user_code"]).to eq("ABCD")
    end

    it "still reaches a plain http origin" do
      stub_request(:get, "#{HTTP}:3001/kiosk/rooms").to_return(json_return(200, []))

      principal = Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1",
                                                token: "tok", rsa_key: nil)

      expect(described_class.new(base_url: "#{HTTP}:3001")
               .query(principal, name: "rooms").status).to eq(200)
    end
  end

  # The blast radius the README's claim actually rides on: a Runner builds its
  # own Client, so an adopter pointing the battery at their deployment never
  # touches the constructor this file is about.
  describe Kiosk::Redteam::Runner do
    it "drives a scenario against an https origin" do
      stub_request(:get, %r{\Ahttps://provider\.test/kiosk/auth/challenge})
        .to_return(json_return(200, "challenge" => "nonce", "exp" => Time.now.to_i + 120))
      stub_request(:post, "#{HTTPS}/kiosk/auth/register").to_return(problem_return("forbidden"))

      reached = Class.new(Kiosk::Redteam::Scenario) do
        def call(client, _profile)
          response = client.register_raw(name: "probe", pow: :skip)
          Kiosk::Redteam::Verdict.new(blocked: Kiosk::Redteam.blocked?(response),
                                      skipped: false, status: response.status,
                                      detail: "")
        end
      end.new(name: "reaches the origin", category: "wire",
              description: "the battery can dial a TLS deployment")

      runner = described_class.new(base_url: HTTPS, profile: Kiosk::Redteam::Profile.new)
      runner.run([reached])

      expect(runner.all_blocked?).to be(true)
      expect(a_request(:post, "#{HTTPS}/kiosk/auth/register")).to have_been_made
    end
  end
end
