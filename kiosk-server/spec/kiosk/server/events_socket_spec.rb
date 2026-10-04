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
    # ADR-0040: `connect` runs after the upgrade request has returned, so the
    # connection resolves the issuer from its own request.
    it "resolves the identity under the origin the upgrade arrived on" do
      expect(report["default_origin_issuer"]).to eq(report["default_origin"])
      expect(report["second_origin_welcomed"]).to be(true)
      expect(report["second_origin_issuer"]).to eq(report["second_origin"])
    end

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

  # Spec Section 8.5.4 forbids a silent subscription because a subscriber would
  # wait on it forever, and Section 8.5.7 leaves exactly two forms to refuse
  # one with. A frame the origin cannot act on is the same harm by another
  # route, so it gets one of the same two.
  #
  # Every example reads the whole frame LIST that arrived after the welcome,
  # never the first match: a second frame contradicting the first is the defect
  # worth catching, and `reconnect` is what a subscriber acts on.
  describe "a frame the origin cannot act on" do
    let(:bad) { report["bad_frames"] || {} }

    def answer(name) = bad.dig(name, "answer")

    # A `subscribe` names a subscription by its `identifier` STRING, which the
    # wire compares and never parses — so the string correlates the refusal
    # whether or not it happens to be a JSON document, and the per-subscription
    # form is the one that leaves the rest of the socket working.
    it "REJECTS a subscribe whose identifier is not a JSON document, echoing it" do
      expect(answer("unparsed_id"))
        .to eq([{ "identifier" => "NOT JSON", "type" => "reject_subscription" }])
      expect(bad.dig("unparsed_id", "closed")).to be(false)
    end

    it "REJECTS a subscribe naming a channel that is not KioskEvents, echoing it" do
      expect(answer("foreign_channel"))
        .to eq([{ "identifier" => '{"channel":"Object","topic":"todo"}',
                  "type" => "reject_subscription" }])
      expect(bad.dig("foreign_channel", "closed")).to be(false)
    end

    # The rest name no subscription, so there is nothing to echo and nothing to
    # refuse. `reconnect: false` because a client whose frames are malformed
    # does not fix them by coming back — the reconnect-storm reasoning Section
    # 8.5.6 states for `revoked`.
    %w[not_json no_identifier unknown_command].each do |shape|
      it "CLOSES with reconnect false on #{shape.tr('_', ' ')}" do
        expect(answer(shape))
          .to eq([{ "type" => "disconnect", "reason" => "invalid_request",
                    "reconnect" => false }])
        expect(bad.dig(shape, "closed")).to be(true)
      end
    end

    it "drives the five literal strings the finding drove" do
      expect(bad.transform_values { |v| v["sent"] }).to eq(
        "not_json" => "this is not json",
        "no_identifier" => '{"command":"subscribe"}',
        "unparsed_id" => '{"command":"subscribe","identifier":"NOT JSON"}',
        "unknown_command" =>
          '{"command":"detonate","identifier":"{\"channel\":\"KioskEvents\",\"topic\":\"todo\"}"}',
        "foreign_channel" =>
          '{"command":"subscribe","identifier":"{\"channel\":\"Object\",\"topic\":\"todo\"}"}',
      )
    end

    # What says the refusal is aimed at a FRAME and not at a client: the socket
    # that was just told off subscribes normally straight afterwards.
    it "goes on serving a well-formed subscribe on the same socket" do
      expect(report["after_bad_frame_subscribed"]).to eq(["order_payment"])
    end
  end

  # Spec Section 8.5.4, and the half a gate on the frame's own members cannot
  # see: each of these IS a JSON object carrying one of the two commands and an
  # `identifier` string naming `KioskEvents`, and Action Cable answers all
  # three with a silence of its own.
  describe "a frame the origin cannot act on for a reason inside the identifier" do
    it "REJECTS an unsubscribe naming a subscription this socket never opened" do
      expect(report.dig("unopened_unsubscribe", "answer"))
        .to eq([{ "identifier" => '{"channel":"KioskEvents","topic":"order_payment"}',
                  "type" => "reject_subscription" }])
      expect(report.dig("unopened_unsubscribe", "closed")).to be(false)
    end

    # The identifier is COMPARED, so the same members in another order name a
    # different subscription — a client that re-serialised it rather than
    # echoing it is told so instead of left waiting.
    it "REJECTS an unsubscribe whose identifier was re-serialised rather than echoed" do
      expect(report.dig("reserialised_unsubscribe", "answer"))
        .to eq([{ "identifier" => '{"subject":"list_ok","topic":"todo","channel":"KioskEvents"}',
                  "type" => "reject_subscription" }])
      expect(report.dig("reserialised_unsubscribe", "closed")).to be(false)
    end

    # Subscribing without the cursor would lose exactly the events the cursor
    # was presented to recover, so the subscription is refused instead.
    it "REJECTS a subscribe whose since is not a cursor" do
      expect(report.dig("unreadable_cursor", "answer"))
        .to eq([{ "identifier" =>
                    '{"channel":"KioskEvents","topic":"todo","subject":"list_ok","since":{}}',
                  "type" => "reject_subscription" }])
      expect(report.dig("unreadable_cursor", "closed")).to be(false)
    end

    # Spec Section 8.5.4: a cursor is an `id` or a `head` the origin sent — a
    # non-negative JSON integer within the range JSON carries exactly.
    {
      "word" => "abc", "digits_as_string" => "880", "negative" => -1,
      "below_range" => -10**30, "above_range" => 2**53, "fraction" => 1.5,
    }.each do |name, since|
      it "REJECTS a subscribe whose since is #{name.tr('_', ' ')}" do
        sent = JSON.generate("channel" => "KioskEvents", "topic" => "todo",
                             "subject" => "list_ok", "since" => since)
        expect(report.dig("not_cursors", name, "answer"))
          .to eq([{ "identifier" => sent, "type" => "reject_subscription" }])
        expect(report.dig("not_cursors", name, "closed")).to be(false)
      end
    end

    %w[abc -5 1e3].each do |since|
      it "REJECTS a URL subscription whose since is #{since.inspect}" do
        sent = JSON.generate("channel" => "KioskEvents", "topic" => "todo",
                             "subject" => "list_ok", "since" => since)
        expect(report.dig("url_not_cursors", since))
          .to eq([{ "identifier" => sent, "type" => "reject_subscription" }])
      end
    end

    # A topic whose reach needs no rule of the operator's would otherwise open
    # these, and no event's subject can match them.
    { "list" => %w[ord_1 ord_2], "number" => 5 }.each do |name, subject|
      it "REJECTS a subscribe whose subject is a #{name}" do
        sent = JSON.generate("channel" => "KioskEvents", "topic" => "order_payment",
                             "subject" => subject)
        expect(report.dig("not_subjects", name, "answer"))
          .to eq([{ "identifier" => sent, "type" => "reject_subscription" }])
      end
    end

    it "accepts the largest cursor" do
      expect(report.dig("largest_cursor", "answer").first.dig("message", "type")).to eq("subscribed")
    end
  end

  # Spec Section 8.5.4: the one frame the origin CAN act on where the action is
  # nothing. Not refused — a subscriber correlates by identifier alone, so it
  # would read a `reject_subscription` as the live subscription's and tear down
  # something that works.
  describe "a second subscribe for a subscription already live" do
    it "CONFIRMS it again, and says nothing else" do
      expect(report.dig("duplicate_subscribe", "answer"))
        .to eq([{ "identifier" => '{"channel":"KioskEvents","topic":"todo","subject":"list_ok"}',
                  "type" => "confirm_subscription" }])
      expect(report.dig("duplicate_subscribe", "closed")).to be(false)
    end

    it "leaves it delivering, with no second subscribed and no second replay" do
      expect(report["after_duplicate_subscribed"]).to eq(1)
      expect(report["after_duplicate_delivered"]).to eq(1)
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

    # Spec Sections 8.5.2 and 8.5.4: `data` MUST validate against the topic's
    # own `payload_schema`, and a subscriber tells one subscription's frames
    # from another's by the echoed `identifier`. The live stream is per
    # (identity, topic), so only the REPLAY can reach another topic — it reads
    # the identity's whole tail — and a subscriber handed another topic's event
    # inside this identifier rejects a legitimately delivered frame.
    it "does NOT replay another TOPIC's event to a subscription that named one" do
      expect(report["replayed_topics"]).to eq(["order_payment"])
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

  # Spec Sections 8.5.3 and 16.1 item 9: `events` is an OPTIONAL module, and an
  # origin that declares no topic answers `501 module_not_served` at
  # `<endpoint>/events` — the answer `pay` and KYC give at their own published
  # paths — rather than welcoming a socket that can never carry anything.
  #
  # Its own subprocess, because the subject is the whole origin: the topics are
  # declared at boot and there is no later moment at which one goes away.
  describe "an origin that declares no topic" do
    before(:context) do
      port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
      probe = File.expand_path("../../support/events_socket_probe_app.rb", __dir__)
      output = IO.popen({ "PROBE_PORT" => port.to_s, "PROBE_NO_TOPICS" => "1" },
                        ["ruby", probe], err: File::NULL, &:read)
      line = output.to_s.lines.reverse.find { |l| l.strip.start_with?("{") }
      @bare = line ? JSON.parse(line) : { "error" => "probe printed no report: #{output.to_s[0, 400]}" }
    end

    let(:bare) { @bare }

    let(:problem) do
      { "type" => "https://kiosk.tech/problems/module_not_served",
        "title" => "Module not served",
        "status" => 501,
        "detail" => "this operator does not serve the events module",
        "code" => "module_not_served",
        "hint" => "`events` is absent from this origin's capabilities and it publishes no " \
                  "events_url; there is nothing to subscribe to here" }
    end

    it "completed every scenario" do
      expect(bare["error"]).to be_nil
      expect(bare["ok"]).to be(true)
    end

    # Which is what makes the refusals below mean something: the module is
    # absent because nothing declared a topic, not because anything failed.
    it "declares no topic, and advertises no events capability" do
      expect(bare["known_topics"]).to eq([])
      expect(bare["capabilities"]).to eq(%w[schema queries])
    end

    it "answers a plain request with the module_not_served problem document" do
      expect(bare["plain"]["status"]).to eq("HTTP/1.1 501 Not Implemented")
      expect(bare["plain"]["content_type"]).to eq("content-type: application/problem+json")
      expect(JSON.parse(bare["plain"]["body"])).to eq(problem)
    end

    it "answers a WebSocket upgrade the same way, at the HTTP layer" do
      expect(bare["upgrade"]["status"]).to eq("HTTP/1.1 501 Not Implemented")
      expect(bare["upgrade"]["content_type"]).to eq("content-type: application/problem+json")
      expect(JSON.parse(bare["upgrade"]["body"])).to eq(problem)
    end

    # Whether this origin publishes events at all is a fact about the ORIGIN and
    # true of every caller, so it is answered before a credential is read —
    # where an origin that DOES serve topics completes the handshake and then
    # sends the `unauthorized` disconnect asserted above.
    it "answers an upgrade carrying no credential identically" do
      expect(JSON.parse(bare["anonymous_upgrade"]["body"])).to eq(problem)
      expect(bare["anonymous_upgrade"]).to eq(bare["upgrade"])
    end

    # Asserted as a LIST for the reason the refused upgrade above is: the defect
    # would be a socket that opens and then says something.
    it "leaves a real client with no socket and no frame" do
      expect(bare["upgrade_frames"]).to eq([])
      expect(bare["upgrade_open"]).to be(false)
    end
  end
end
