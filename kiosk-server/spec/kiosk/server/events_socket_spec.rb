# frozen_string_literal: true

require "json"
require "socket"

# The event stream, driven over a REAL WebSocket against a REAL server
# (T-169 phase A task 5).
#
# Everything here is asserted from spec/support/events_socket_probe_app.rb, run
# as a subprocess: it boots Rails with the engine mounted, serves it on Puma
# (the only server in this bundle that supports `rack.hijack`, which Action
# Cable's connection requires), and drives the scenarios with a client built on
# `websocket-driver` — Action Cable's own transitive dependency, so the suite
# gains neither a gem nor an interpreter.
#
# Written this way because the alternative proves nothing: a channel exercised
# through `ActionCable::Channel::TestCase` never negotiates a subprotocol, never
# meets Action Cable's origin check and never hijacks a socket, and all three of
# those are where this surface is actually load-bearing.
RSpec.describe "the Kiosk event stream over a real socket" do
  # One subprocess for every example in this file: booting Rails and Puma costs
  # seconds, and each assertion below reads a different field of the one report.
  before(:context) do
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    probe = File.expand_path("../../support/events_socket_probe_app.rb", __dir__)
    output = IO.popen({ "PROBE_PORT" => port.to_s }, ["ruby", probe], err: File::NULL, &:read)
    line = output.to_s.lines.reverse.find { |l| l.strip.start_with?("{") }
    @report = line ? JSON.parse(line) : { "error" => "probe printed no report: #{output.to_s[0, 400]}" }
  end

  let(:report) { @report }

  it "completed every scenario" do
    expect(report["error"]).to be_nil
    expect(report["ok"]).to be(true)
  end

  describe "the upgrade" do
    # Action Cable finishes the handshake and THEN runs `connect`, so a refused
    # upgrade still answers 101 and closes immediately after. The `welcome`
    # frame is therefore the only thing that separates accepted from refused —
    # reading the 101 as success is how an unauthenticated socket looks open.
    it "refuses a caller presenting no Authorization header" do
      expect(report["no_auth_welcomed"]).to be(false)
    end

    it "refuses a caller presenting a token the IdP does not know" do
      expect(report["bad_token_welcomed"]).to be(false)
    end

    it "accepts a caller the ordinary identity chain resolves, and welcomes it" do
      expect(report["opened"]).to be(true)
      expect(report["welcome"]).to eq("type" => "welcome")
    end
  end

  describe "subscribing" do
    it "confirms a declared topic with head and truncated" do
      expect(report["subscribed"]).to include(
        "type" => "subscribed", "topic" => "order_payment", "truncated" => false
      )
      expect(report["subscribed"]["head"]).to be_a(Integer)
    end

    # A silent subscription to nothing is indistinguishable from a quiet topic,
    # and a client that mistyped a name would wait on it forever.
    it "REJECTS a topic this origin does not declare, rather than streaming it empty" do
      expect(report["undeclared_rejected"]).to be(true)
    end

    it "REJECTS a consented topic whose subject the operator says is unreachable" do
      expect(report["unreachable_subject_rejected"]).to be(true)
    end

    it "accepts the same topic for a subject the operator says IS reachable" do
      expect(report["reachable_subject_subscribed"]).to be(true)
    end
  end

  describe "delivery" do
    it "pushes an emitted event carrying the five closed members and no others" do
      expect(report["live"]).not_to be_nil
      expect(report["live"].keys)
        .to contain_exactly("id", "topic", "subject", "occurred_at", "data")
      expect(report["live"]).to include("topic" => "order_payment", "subject" => "ord_1",
                                        "data" => { "status" => "paid" })
    end

    it "does NOT deliver another subject's event to a subject-scoped subscription" do
      expect(report["other_subject_delivered"]).to be(false)
    end
  end

  # BOTH ways, deliberately: a single-use connect ticket AND subscriptions
  # declarable in the URL. Neither is removed until there is a real harness on
  # the other end to choose with — and the measurement that produced the pair
  # says a ticket ALONE buys nothing, because a receive-only client still could
  # not issue a `subscribe` command.
  describe "the connect ticket" do
    it "refuses to mint for an unauthenticated caller" do
      expect(report["ticket_unauth_status"]).to eq(401)
    end

    it "mints for the ordinary identity chain, short-lived" do
      expect(report["ticket_status"]).to eq(200)
      expect(report["ticket_minted"]).to be(true)
      expect(report["ticket_expires_in"]).to eq(30)
    end

    it "opens a socket that sends NO Authorization header" do
      expect(report["url_welcomed"]).to be(true)
    end

    # The property that makes a ticket in an access log worthless even inside
    # its thirty seconds.
    it "is SINGLE USE — the same ticket a second time is refused" do
      expect(report["ticket_replay_welcomed"]).to be(false)
    end

    it "refuses a ticket nobody minted" do
      expect(report["bogus_ticket_welcomed"]).to be(false)
    end
  end

  describe "subscriptions declared in the URL" do
    # Without this half the ticket is pointless: Action Cable streams nothing
    # until the client SENDS a subscribe command, and a receive-only client
    # never can — it would hold an open socket and receive nothing, forever.
    it "subscribes to every topic in the query string without the client sending a frame" do
      expect(report["url_subscribed_topics"]).to eq(%w[order_payment todo])
    end

    # THE RACE THIS FOUND. `stream_from` posts its pubsub subscribe to Action
    # Cable's event loop and defers `confirm_subscription` until it lands, so
    # between our `subscribed` frame and a live stream there was a window in
    # which an emitted event reached nobody at all. The probe emits inside that
    # window on purpose; the channel closes it by replaying from the head it
    # captured BEFORE opening the stream, at confirmation time.
    it "delivers an event emitted between the subscribed frame and a live stream" do
      expect(report["url_delivered"]).to be(true)
    end
  end

  describe "resuming with `since`" do
    # A socket that missed events gets exactly the gap back, and nothing it had
    # already seen (spec Section 8.5.5).
    it "replays only what the cursor had not seen" do
      expect(report["resumed_ids"]).to eq(report["resumed_ids"].sort)
      expect(report["resumed_ids"].first).to be > 1
    end

    it "reports head on the resumed subscription" do
      expect(report["resume_head"]).to include("type" => "subscribed")
      expect(report["resume_head"]["head"]).to be >= report["resumed_ids"].max
    end

    # "I cannot prove you saw everything" — one ordinary tolled read, never a
    # silent gap, and it is REQUIRED rather than optional for that reason.
    it "says truncated when the cursor predates what the store still holds" do
      expect(report["truncated_frame"]).to include("truncated" => true)
    end
  end
end
