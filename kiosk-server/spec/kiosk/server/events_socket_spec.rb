# frozen_string_literal: true

require "json"
require "socket"

# The event stream, driven over a REAL WebSocket against a REAL server
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

    # Spec Section 8.5.3: an operator MUST NOT accept the access token anywhere
    # but the `Authorization` header. The token here is the good one — what is
    # refused is the PLACE, so this fails if the engine ever grows a second
    # route in.
    it "refuses a VALID token presented only in the query string" do
      expect(report["query_token_welcomed"]).to be(false)
    end

    it "accepts a caller the ordinary identity chain resolves, and welcomes it" do
      expect(report["opened"]).to be(true)
      expect(report["welcome"]).to eq("type" => "welcome")
    end

    # Spec Section 8.5.3: the `Authorization` header is the whole of what
    # authorises an upgrade, and an operator MUST NOT refuse one over its
    # `Origin`. That header is a browser's forgery control, and a browser
    # cannot attach `Authorization` cross-origin in the first place — so
    # requiring it would only lock out the stacks this wire is written for.
    it "accepts an upgrade that carries NO Origin header" do
      expect(report["no_origin_welcomed"]).to be(true)
    end

    it "accepts an upgrade whose Origin names somewhere else entirely" do
      expect(report["foreign_origin_welcomed"]).to be(true)
    end

    # Spec Section 8.5.3: an operator that completes the handshake and then
    # refuses on the credential MUST say so. Without it the refused socket is
    # open, silent and indistinguishable from a quiet one.
    it "tells a refused upgrade so, and says nothing else" do
      expect(report["no_auth_frames"])
        .to eq([{ "type" => "disconnect", "reason" => "unauthorized", "reconnect" => false }])
    end
  end

  # Spec Section 8.5.4. The envelope is the wire a port has to produce, and the
  # level a frame arrives at is what a subscriber reads it by: a subscription's
  # own frames are wrapped, the connection's are not.
  describe "the actioncable-v1-json framing" do
    it "wraps a subscription's own frames, echoing the identifier it was given" do
      expect(report["subscribed_envelope"].keys).to contain_exactly("identifier", "message")
      expect(JSON.parse(report["subscribed_envelope"]["identifier"]))
        .to eq("channel" => "KioskEvents", "topic" => "order_payment")
    end

    it "confirms a live subscription at top level, with the identifier and no message" do
      expect(report["confirmation"])
        .to eq("identifier" => report["subscribed_envelope"]["identifier"],
               "type" => "confirm_subscription")
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

    # The refusal is right — the safe reading of a broken authorisation rule is
    # NO. What the wire cannot carry is WHOSE code broke, so the engine says it
    # in its own log; without that line the operator sees a refusal
    # indistinguishable from their rule answering no.
    it "REFUSES when the operator's own subject rule raises, and logs what raised" do
      expect(report["raising_rule_rejected"]).to be(true)
      expect(report["raising_rule_logged"]).to be(true)
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

  describe "subscriptions declared in the URL" do
    # Action Cable streams nothing until the client SENDS a subscribe command,
    # and a client that can set a header on the upgrade may still be unable to
    # send a frame — it would hold an open socket and receive nothing, forever.
    # So everything such a client has to say, it says in the URL.
    it "welcomes a socket whose topics arrive only in the query string" do
      expect(report["url_welcomed"]).to be(true)
    end

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

  # Spec Section 8.5.6: a subscription is authorised again WHILE IT STANDS, at
  # least every 60 seconds. The three examples are the three answers the timer
  # can reach, and the first is the one that makes the other two mean
  # something: a socket nothing has changed under is left alone.
  describe "re-authorisation while the subscription stands" do
    it "leaves a subscription whose reach and credential still hold alone" do
      expect(report["steady_unsubscribed"]).to be(false)
      expect(report["steady_disconnected"]).to be(false)
    end

    it "stops delivering and says why when the subject's reach is withdrawn" do
      expect(report["reach_revoked_frame"])
        .to eq("type" => "unsubscribed", "topic" => "todo", "reason" => "reach_revoked")
      expect(report["other_socket_unsubscribed"]).to be(false)
    end

    # Asserted as a LIST, exactly as the refused upgrade above is. `reconnect`
    # is the thing a subscriber acts on, so a second disconnect frame carrying
    # the opposite flag is the whole defect — and reading the first matching
    # frame cannot see one.
    it "closes the connection with reconnect false when the credential stops resolving" do
      expect(report["revoked_frames"])
        .to eq([{ "type" => "disconnect", "reason" => "revoked", "reconnect" => false }])
      expect(report["revoked_socket_closed"]).to be(true)
    end

    # The one case where coming back WOULD have worked: an access token is
    # short-lived and a held socket outlives it, so the assistant mints another
    # by challenge-response and resumes from its cursor. The two sockets differ
    # in nothing but their credential's `exp`.
    it "tells a client whose access token merely aged out to come back" do
      expect(report["expired_frames"])
        .to eq([{ "type" => "disconnect", "reason" => "token_expired", "reconnect" => true }])
    end
  end
end
