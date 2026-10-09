# frozen_string_literal: true

# The socket probe behind spec/kiosk/server/events_socket_spec.rb — run as a
# SUBPROCESS, never loaded into the RSpec process.
#
# Out-of-process for the reason engine_mount_probe_app.rb gives (booting Rails
# inside the suite mutates it globally) and for one more of its own: this boots
# PUMA and holds real TCP sockets, and a server thread that outlives an example
# is a flake in every example after it.
#
# It boots a Rails application with kiosk-server loaded and the engine mounted,
# declares the topics the scenarios need, installs a fake agent-IdP that accepts
# one bearer token, serves the app on an ephemeral port, then drives the
# scenarios below over a REAL WebSocket and prints one JSON report on stdout.
#
# The client is built on `websocket-driver`, which Action Cable already depends
# on — so the suite gains no dependency and no interpreter but Ruby.

require "bundler/setup"
require "json"
require "socket"
require "kiosk/server"
require "kiosk/pow"
require "kiosk/reputation"
require "puma"
require "puma/configuration"
require "puma/launcher"
require "websocket/driver"
require "openssl"
require "stringio"

REPORT = {}
# The engine's own log, so a scenario can assert a line the wire cannot carry.
# ERROR level only: everything below it is request noise.
LOG = StringIO.new

# Declare no topic, so this boots the OTHER origin the spec needs: one that
# serves no events module at all and answers the mount accordingly.
NO_TOPICS = ENV["PROBE_NO_TOPICS"] == "1"

# ── a fake agent-IdP: one token, one identity ────────────────────────────────
GOOD_TOKEN = "good-token"
REVOKED    = { value: false }
# The operator's answer to "may this subscriber read this subject", flipped
# under a socket that is already holding one.
REACHABLE  = { value: true }
# The `exp` this IdP stamps on the identity it resolves, and after which it
# stops resolving at all. Moved back under a held socket to age its token out.
EXPIRES_AT = { value: Time.now.to_i + 3600 }
# The issuer in force each time the IdP was asked, newest last.
ISSUERS_SEEN = []

class ProbeIdp
  def verify(request)
    ISSUERS_SEEN << Kiosk.current_issuer
    header = request.headers["Authorization"] || request.headers["HTTP_AUTHORIZATION"]
    return nil unless header.to_s == "Bearer #{GOOD_TOKEN}"
    return nil if REVOKED[:value]
    return nil if Time.now.to_i >= EXPIRES_AT[:value]

    Kiosk::Identity.new(user_id: "u1", role: "customer", actor: "agent", agent_id: "a1",
                        claims: { exp: EXPIRES_AT[:value] })
  end
end

class ProbeController < ActionController::Base
  include Kiosk::Handler

  unless NO_TOPICS
    topic :order_payment do
      description "Your order was paid."
      payload_schema type: "object"
    end

    topic :todo do
      reach :consented
      description "A todo on a list you can reach changed."
      payload_schema type: "object"
      subject_reachable ->(subject, _identity) { REACHABLE[:value] && subject.to_s == "list_ok" }
    end

    topic :boom do
      reach :consented
      description "A topic whose own subject rule raises."
      payload_schema type: "object"
      subject_reachable ->(_subject, _identity) { raise "operator rule blew up" }
    end
  end

  kind :query
  description "Lists nothing, so the origin has a verb and a catalogue."
  input_schema type: "object", additionalProperties: false, properties: {}
  output_schema type: "array", items: { type: "object" }
  def list_nothing
    render json: []
  end
end

Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
TOLL_EVERY_VERB = Class.new(Kiosk::Reputation::Policy) do
  def challenge_for(identity:, verb:, factors:) = { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8) }
end.new

class ProbeApp < Rails::Application
  config.eager_load = false
  config.paths["config"] << File.expand_path("config", __dir__)
  config.hosts.clear
  config.logger = Logger.new(LOG, level: Logger::ERROR)
  config.secret_key_base = "x" * 64
end

Kiosk.configure do |c|
  c.issuer    = "http://127.0.0.1:#{ENV.fetch("PROBE_PORT")}"
  c.additional_origins = ["http://localhost:#{ENV.fetch("PROBE_PORT")}"]
  c.agent_idp = ProbeIdp.new
  # A real key, generated here: the engine crashes rather than inventing one
  # outside development, which is the posture we want and the reason a fixture
  # booted in production has to bring its own.
  c.signing_key = Kiosk::Server::SigningKey.from_pem(OpenSSL::PKey::RSA.new(2048).to_pem)
  # Every verb on this origin is tolled, so every scenario below also says
  # the stream is not (spec Section 8.5.3).
  c.reputation_policy = TOLL_EVERY_VERB
  c.pow_secret = "probe-pow-secret-of-at-least-32-bytes"
end

# The shipped re-authorisation period is thirty seconds. Shortened to one so a
# scenario that waits for a tick finishes inside the suite; the registration
# itself — `periodically :reauthorise!` — is the shipped one, untouched.
KioskEvents.periodic_timers =
  KioskEvents.periodic_timers.map { |callback, options| [callback, options.merge(every: 1)] }
Kiosk::Server::EventsConnection.reauthorise_every = 1

# Action Cable's three-second beat, shortened the same way so two pings arrive
# inside the suite; the thinning to one ping per BEATS_PER_PING is the shipped one.
SHIPPED_BEAT_INTERVAL = ActionCable::Server::Connections::BEAT_INTERVAL
PROBE_BEAT_INTERVAL = 0.2
ActionCable::Server::Connections.send(:remove_const, :BEAT_INTERVAL)
ActionCable::Server::Connections.const_set(:BEAT_INTERVAL, PROBE_BEAT_INTERVAL)

ProbeApp.initialize!
ProbeApp.routes.draw do
  mount Kiosk::Server::Engine => "/kiosk"
  get "/kiosk/list_nothing", to: "kiosk/server/verb#show", defaults: { kiosk_verb: "list_nothing" }
end

# ── the client ───────────────────────────────────────────────────────────────
class ProbeSocket
  # Pings are kept apart, with their arrival time, so no scenario's frame list
  # depends on when a beat happened to fall.
  attr_reader :frames, :pings

  def initialize(port, path, headers, host: "127.0.0.1")
    @url = "ws://#{host}:#{port}#{path}"
    @tcp = TCPSocket.new("127.0.0.1", port)
    @frames = []
    @pings = []
    @open = false
    @closed = false
    @driver = WebSocket::Driver.client(self, protocols: ["actioncable-v1-json"])
    headers.each { |k, v| @driver.set_header(k, v) }
    @driver.on(:open)    { @open = true }
    @driver.on(:message) do |e|
      frame = JSON.parse(e.data)
      frame["type"] == "ping" ? @pings << [Time.now, frame] : @frames << frame
    end
    @driver.on(:close)   { @closed = true }
    @driver.on(:error)   { @closed = true }
    @driver.start
  end

  def url = @url
  def write(data) = @tcp.write(data)

  # Pump until the block is satisfied or the deadline passes. Returns whether
  # it was satisfied, so every assertion below is a fact about what ARRIVED
  # rather than about how long we happened to wait.
  def pump_until(seconds: 4)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      break if @closed

      ready = IO.select([@tcp], nil, nil, 0.1)
      next unless ready

      begin
        @driver.parse(@tcp.read_nonblock(8192))
      rescue IO::WaitReadable
        next
      rescue EOFError, Errno::ECONNRESET
        @closed = true
      end
    end
    yield
  end

  def open? = @open
  # The subprotocol the server answered in `Sec-WebSocket-Protocol`, or nil.
  def protocol = @driver.protocol
  def closed? = @closed

  # A frame exactly as typed. Several scenarios below drive strings no client
  # library would construct, which is the whole point of them.
  def send_raw(text) = @driver.text(text)

  def subscribe(identifier)
    send_raw(JSON.generate("command" => "subscribe", "identifier" => JSON.generate(identifier)))
  end

  def messages = frames.filter_map { |f| f["message"] }

  def close
    @tcp.close
  rescue StandardError
    nil
  end
end

def identifier(topic, **rest)
  { "channel" => "KioskEvents", "topic" => topic }.merge(rest.transform_keys(&:to_s))
end

def frame(command, identifier) = JSON.generate("command" => command,
                                               "identifier" => JSON.generate(identifier))

# The subscription the already-live scenarios below are driven against.
SUBSCRIBE_TODO = frame("subscribe", identifier("todo", subject: "list_ok"))

# One frame on its own socket, and everything that came back after it. `live`
# opens a subscription first, for the cases that are about a frame naming one
# the socket already holds.
def frame_answer(port, text, live: nil)
  sock = connect(port)
  sock.pump_until { sock.frames.any? }
  if live
    sock.send_raw(live)
    sock.pump_until { sock.frames.any? { |f| f["type"] == "confirm_subscription" } }
  end
  sent = sock.frames.length
  sock.send_raw(text)
  sock.pump_until(seconds: 3) { sock.frames.length > sent }
  answer = { "sent" => text, "answer" => sock.frames[sent..], "closed" => sock.closed? }
  sock.close
  answer
end

# Frames an origin cannot act on, as the literal strings a broken client sends.
# A `subscribe` naming a subscription is refusable, however little sense the
# `identifier` makes; the rest name none.
BAD_FRAMES = {
  "not_json"        => "this is not json",
  "no_identifier"   => '{"command":"subscribe"}',
  "unparsed_id"     => '{"command":"subscribe","identifier":"NOT JSON"}',
  "unknown_command" => '{"command":"detonate","identifier":"{\"channel\":\"KioskEvents\",\"topic\":\"todo\"}"}',
  "foreign_channel" => '{"command":"subscribe","identifier":"{\"channel\":\"Object\",\"topic\":\"todo\"}"}',
}.freeze

# Values a `subscribe` may present as `since` that are not a cursor.
NOT_CURSORS = {
  "word" => "abc", "digits_as_string" => "880", "negative" => -1,
  "below_range" => -10**30, "above_range" => 2**53, "fraction" => 1.5,
}.freeze

UPGRADE_HEADERS = {
  "Connection" => "Upgrade", "Upgrade" => "websocket", "Sec-WebSocket-Version" => "13",
  "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==",
  "Sec-WebSocket-Protocol" => "actioncable-v1-json",
}.freeze

# One request, and the whole of what came back off the socket — which is what a
# client reads when an upgrade is answered at the HTTP layer instead. Reads
# until the response is complete (its Content-Length, or the server closing),
# bounded by one overall deadline rather than a silence window.
def raw_get(port, path, headers)
  socket = TCPSocket.new("127.0.0.1", port)
  lines  = ["GET #{path} HTTP/1.1", "Host: 127.0.0.1:#{port}"] + headers.map { |k, v| "#{k}: #{v}" }
  socket.write("#{lines.join("\r\n")}\r\n\r\n")
  raw      = +""
  deadline = Time.now + 15
  until response_complete?(raw)
    remaining = deadline - Time.now
    break unless remaining.positive? && IO.select([socket], nil, nil, remaining)
    begin
      raw << socket.readpartial(4096)
    rescue EOFError
      break
    end
  end
  socket.close
  head, _, body = raw.partition("\r\n\r\n")
  { "status" => head.lines.first.to_s.strip,
    "content_type" => head.lines.grep(/^content-type:/i).first.to_s.strip,
    "body" => body }
end

def response_complete?(raw)
  head, separator, body = raw.partition("\r\n\r\n")
  return false if separator.empty?
  length = head[/^content-length:[[:space:]]*([[:digit:]]+)/i, 1]
  length && body.bytesize >= length.to_i
end

def connect(port, headers: nil, path: "/kiosk/events", host: "127.0.0.1")
  ProbeSocket.new(port, path, headers || {
    "Origin" => Kiosk.configuration.issuer,
    "Authorization" => "Bearer #{GOOD_TOKEN}",
  }, host: host)
end

# ── boot Puma ────────────────────────────────────────────────────────────────
port = ENV.fetch("PROBE_PORT").to_i
conf = Puma::Configuration.new do |user_config|
  user_config.bind "tcp://127.0.0.1:#{port}"
  user_config.app ProbeApp
  user_config.threads 2, 4
  user_config.environment "production"
end
launcher = Puma::Launcher.new(conf, events: Puma::Events.new)
Thread.new { launcher.run }

# Wait for the listener, and FAIL rather than hang if it never comes: a probe
# that blocks forever is read as a hung suite, which says nothing about the
# subject.
listening = false
40.times do
  begin
    TCPSocket.new("127.0.0.1", port).close
    listening = true
    break
  rescue Errno::ECONNREFUSED
    sleep 0.1
  end
end
unless listening
  puts JSON.generate(error: "puma never listened on #{port}")
  exit 0
end

# ── the origin that declares no topic ────────────────────────────────────────
#
# It serves no events module, so the mount answers the problem document rather
# than upgrading — for a plain request, for an upgrade, and before any
# credential is read. Nothing below this applies to such an origin.
if NO_TOPICS
  REPORT[:known_topics] = Kiosk::Server::Events.known
  REPORT[:capabilities] =
    JSON.parse(raw_get(port, "/.well-known/kiosk.json", "Connection" => "close")["body"])
        .dig("kiosk", "capabilities")
  REPORT[:plain]   = raw_get(port, "/kiosk/events", "Connection" => "close")
  REPORT[:upgrade] =
    raw_get(port, "/kiosk/events", UPGRADE_HEADERS.merge("Authorization" => "Bearer #{GOOD_TOKEN}"))
  REPORT[:anonymous_upgrade] = raw_get(port, "/kiosk/events", UPGRADE_HEADERS)
  # And what a real client makes of it: the driver never opens, and no frame
  # arrives for it to read.
  sock = connect(port)
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:upgrade_frames] = sock.frames
  REPORT[:upgrade_open]   = sock.open?
  sock.close
  REPORT[:ok] = true
  puts JSON.generate(REPORT)
  exit 0
end

store = Kiosk.configuration.event_store

begin
  # 0 — the toll is on: a verb called with a good credential and no proof is
  #     challenged, which is what makes every accepted upgrade below free.
  REPORT[:tolled_verb_status] =
    raw_get(port, "/kiosk/list_nothing", "Authorization" => "Bearer #{GOOD_TOKEN}",
                                         "Connection" => "close")["status"]

  # 1 — no Authorization: the upgrade is refused.
  sock = connect(port, headers: { "Origin" => Kiosk.configuration.issuer })
  # Action Cable completes the WebSocket handshake and THEN runs `connect`, so
  # a refused upgrade still answers 101 and is closed immediately after. The
  # fact that separates accepted from refused is therefore the `welcome` frame,
  # never the 101.
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:no_auth_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  # Everything the refused socket is told before it goes, which is the typed
  # disconnect spec Section 8.5.3 names and nothing else.
  sock.pump_until(seconds: 2) { sock.closed? }
  REPORT[:no_auth_frames] = sock.frames
  sock.close

  # 2 — a bad token: refused.
  sock = connect(port, headers: { "Origin" => Kiosk.configuration.issuer,
                                  "Authorization" => "Bearer nope" })
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:bad_token_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 2b — a GOOD token, but in the query string: refused. Spec Section 8.5.3
  # forbids an operator to accept the access token anywhere but the
  # `Authorization` header, and the engine reads it nowhere else.
  sock = connect(port, headers: { "Origin" => Kiosk.configuration.issuer },
                       path: "/kiosk/events?access_token=#{GOOD_TOKEN}")
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:query_token_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 3 — a good upgrade: 101, and the welcome frame.
  sock = connect(port)
  sock.pump_until { sock.frames.any? }
  REPORT[:opened] = sock.open?
  REPORT[:welcome] = sock.frames.first
  REPORT[:negotiated_protocol] = sock.protocol

  REPORT[:default_origin_issuer] = ISSUERS_SEEN.last

  # 3b — the same upgrade on the second origin resolves under that origin.
  other = connect(port, host: "localhost")
  other.pump_until { other.frames.any? }
  REPORT[:second_origin_welcomed] = other.frames.any? { |f| f["type"] == "welcome" }
  REPORT[:second_origin_issuer] = ISSUERS_SEEN.last
  REPORT[:second_origin] = "http://localhost:#{port}"
  REPORT[:default_origin] = Kiosk.configuration.issuer
  other.close

  # 4 — subscribe to a declared, principal-reach topic.
  sock.subscribe(identifier("order_payment"))
  sock.pump_until { sock.messages.any? { |m| m["type"] == "subscribed" } }
  REPORT[:subscribed] = sock.messages.find { |m| m["type"] == "subscribed" }
  # The FRAME the confirmation travels in, rather than the message inside it:
  # everything about one subscription is wrapped, and everything about the
  # connection is not (spec Section 8.5.4).
  REPORT[:subscribed_envelope] =
    sock.frames.find { |f| f.dig("message", "type") == "subscribed" }
  sock.pump_until { sock.frames.any? { |f| f["type"] == "confirm_subscription" } }
  REPORT[:confirmation] = sock.frames.find { |f| f["type"] == "confirm_subscription" }

  # 5 — an UNdeclared topic is rejected, not streamed empty.
  sock.subscribe(identifier("nope"))
  sock.pump_until { sock.frames.any? { |f| f["type"] == "reject_subscription" } }
  REPORT[:undeclared_rejected] =
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("nope") }

  # 6 — a consented topic whose subject is NOT reachable is rejected.
  sock.subscribe(identifier("todo", subject: "list_no"))
  sock.pump_until do
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("list_no") }
  end
  REPORT[:unreachable_subject_rejected] =
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("list_no") }

  # 7 — and the reachable one is accepted.
  sock.subscribe(identifier("todo", subject: "list_ok"))
  sock.pump_until { sock.messages.count { |m| m["type"] == "subscribed" } >= 2 }
  REPORT[:reachable_subject_subscribed] =
    sock.messages.count { |m| m["type"] == "subscribed" } >= 2

  # 7b — a consented topic with NO subject takes everything on it addressed to
  #      this identity, whatever the subject.
  whole = connect(port)
  whole.pump_until { whole.frames.any? }
  whole.subscribe(identifier("todo"))
  whole.pump_until { whole.frames.any? { |f| f["type"] =~ /confirm_subscription|reject_subscription/ } }
  REPORT[:subjectless_consented_answer] =
    whole.frames.find { |f| f["type"] =~ /confirm_subscription|reject_subscription/ }&.dig("type")
  whole_ids = %w[list_ok list_other].map do |subject|
    Kiosk::Server::Events.emit(topic: :todo, subject: subject, identity_scope: %w[u1], data: {})
  end
  whole.pump_until { whole_ids.all? { |id| whole.messages.any? { |m| m["id"] == id } } }
  REPORT[:subjectless_consented_delivered] = whole_ids.all? { |id| whole.messages.any? { |m| m["id"] == id } }
  whole.close

  # 8 — LIVE delivery: emit, and the socket sees it with the five closed members.
  first_id = Kiosk::Server::Events.emit(
    topic: :order_payment, subject: "ord_1", identity_scope: %w[u1],
    data: { "status" => "paid" },
  )
  sock.pump_until { sock.messages.any? { |m| m["id"] == first_id } }
  REPORT[:live] = sock.messages.find { |m| m["id"] == first_id }

  # 9 — subject filtering: an event on another subject of a subject-scoped
  #     subscription must not arrive.
  Kiosk::Server::Events.emit(topic: :todo, subject: "list_other", identity_scope: %w[u1],
                             data: { "done" => true })
  other_id = store.head
  sock.pump_until(seconds: 1) { false }
  REPORT[:other_subject_delivered] = sock.messages.any? { |m| m["id"] == other_id }
  sock.close

  # 10 — RESUME: a second socket subscribing with `since` replays only the gap.
  gap_id = Kiosk::Server::Events.emit(
    topic: :order_payment, subject: "ord_2", identity_scope: %w[u1],
    data: { "status" => "refunded" },
  )
  resumed = connect(port)
  resumed.pump_until { resumed.frames.any? }
  resumed.subscribe(identifier("order_payment", since: first_id))
  resumed.pump_until { resumed.messages.any? { |m| m["id"] == gap_id } }
  REPORT[:resumed_ids] = resumed.messages.filter_map { |m| m["id"] }
  # The tail between the two cursors also holds the step-9 `todo` event, which
  # this subscription did not ask for. Replay reads the whole tail, so this is
  # the one path that can reach another topic at all.
  REPORT[:replayed_topics] = resumed.messages.select { |m| m["id"] }.map { |m| m["topic"] }.uniq
  REPORT[:resume_head] = resumed.messages.find { |m| m["type"] == "subscribed" }
  resumed.close

  # 11 — TRUNCATED: a cursor older than what the store still holds says so.
  store.prune_before(store.head) if store.respond_to?(:prune_before)
  truncated = connect(port)
  truncated.pump_until { truncated.frames.any? }
  truncated.subscribe(identifier("order_payment", since: 0))
  truncated.pump_until { truncated.messages.any? { |m| m["type"] == "subscribed" } }
  REPORT[:truncated_frame] = truncated.messages.find { |m| m["type"] == "subscribed" }
  truncated.close

  # ── URL-declared subscriptions ────────────────────────────────────────────

  # 12 — a client that never SENDS a frame: it authenticates the upgrade the
  #      one way there is, with the header, and names its topics in the query
  #      string. Action Cable would otherwise stream it nothing at all.
  urlsub = connect(port, path: "/kiosk/events?topic=order_payment&topic=todo:list_ok")
  urlsub.pump_until { urlsub.messages.count { |m| m["type"] == "subscribed" } >= 2 }
  REPORT[:url_welcomed] = urlsub.frames.any? { |f| f["type"] == "welcome" }
  REPORT[:url_subscribed_topics] =
    urlsub.messages.select { |m| m["type"] == "subscribed" }.map { |m| m["topic"] }.sort

  # DELIBERATELY emitting on the `subscribed` frame and NOT on Action Cable's
  # later `confirm_subscription`: an event emitted in that window still has to
  # reach the subscriber, and this is the assertion that it does.
  url_id = Kiosk::Server::Events.emit(
    topic: :order_payment, subject: "ord_3", identity_scope: %w[u1], data: { "status" => "paid" },
  )
  urlsub.pump_until(seconds: 6) { urlsub.messages.any? { |m| m["id"] == url_id } }
  REPORT[:url_delivered] = urlsub.messages.any? { |m| m["id"] == url_id }

  urlsub.close

  # 13 — NO `Origin` header at all, and the upgrade is accepted. The
  #      `Authorization` header is the authorisation; `Origin` is a browser's
  #      forgery control and there is no browser on this exchange.
  sock = connect(port, headers: { "Authorization" => "Bearer #{GOOD_TOKEN}" })
  sock.pump_until { sock.frames.any? }
  REPORT[:no_origin_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 14 — an `Origin` naming somewhere else entirely, same answer: a browser
  #      cannot attach the `Authorization` header cross-origin, so the header
  #      that decides this upgrade is one an attacker's page cannot send.
  sock = connect(port, headers: { "Origin" => "https://example.com",
                                  "Authorization" => "Bearer #{GOOD_TOKEN}" })
  sock.pump_until { sock.frames.any? }
  REPORT[:foreign_origin_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 15 — an operator's OWN subject rule raises. The refusal is right, because
  #      the safe reading of a broken authorisation rule is NO — and the
  #      operator whose lambda raised has to be able to find out, which the
  #      wire cannot tell them.
  sock = connect(port)
  sock.pump_until { sock.frames.any? }
  sock.subscribe(identifier("boom", subject: "anything"))
  sock.pump_until do
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("boom") }
  end
  REPORT[:raising_rule_rejected] =
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("boom") }
  REPORT[:raising_rule_logged] =
    LOG.string.include?(%([kiosk] events subject rule raised for topic "boom": RuntimeError: operator rule blew up at #{__FILE__}:))
  sock.close

  # 15b — a frame the origin cannot act on (spec Section 8.5.4). Each on its
  #       own socket, because three of the five answers close it, and each sent
  #       AFTER the welcome so the answer is to the frame and not to the
  #       upgrade. Everything that arrived after the welcome is collected, so a
  #       second frame contradicting the first is visible.
  REPORT[:bad_frames] = {}
  BAD_FRAMES.each do |name, text|
    bad = connect(port)
    bad.pump_until { bad.frames.any? }
    welcomed = bad.frames.length
    bad.send_raw(text)
    bad.pump_until(seconds: 3) { bad.frames.length > welcomed }
    bad.pump_until(seconds: 2) { bad.closed? }
    REPORT[:bad_frames][name] = { "sent" => text, "answer" => bad.frames[welcomed..],
                                  "closed" => bad.closed? }
    bad.close
  end

  # 15c — and a well-formed subscribe on a socket that has just been told off
  #       still works, which is what says the seam above refuses a FRAME and
  #       not a client.
  sock = connect(port)
  sock.pump_until { sock.frames.any? }
  sock.send_raw(BAD_FRAMES["unparsed_id"])
  sock.pump_until { sock.frames.any? { |f| f["type"] == "reject_subscription" } }
  sock.subscribe(identifier("order_payment"))
  sock.pump_until { sock.messages.any? { |m| m["type"] == "subscribed" } }
  REPORT[:after_bad_frame_subscribed] =
    sock.messages.select { |m| m["type"] == "subscribed" }.map { |m| m["topic"] }
  sock.close

  # 15d — frames that name a subscription the origin cannot act on: one the
  #       socket does not hold, and a `since` that is not a cursor.
  REPORT[:unopened_unsubscribe] =
    frame_answer(port, frame("unsubscribe", identifier("order_payment")))
  REPORT[:reserialised_unsubscribe] = frame_answer(
    port,
    frame("unsubscribe",
          "subject" => "list_ok", "topic" => "todo", "channel" => "KioskEvents"),
    live: SUBSCRIBE_TODO,
  )
  REPORT[:unreadable_cursor] =
    frame_answer(port, frame("subscribe", identifier("todo", subject: "list_ok", since: {})))

  # 15d2 — every other `since` that is not a cursor, in both spellings; a
  #        `subject` that is not a string; and the largest cursor there is.
  REPORT[:not_cursors] = NOT_CURSORS.transform_values do |since|
    frame_answer(port, frame("subscribe", identifier("todo", subject: "list_ok", since: since)))
  end
  REPORT[:url_not_cursors] = %w[abc -5 1e3].to_h do |since|
    url = connect(port, path: "/kiosk/events?topic=todo:list_ok&since=#{since}")
    url.pump_until { url.frames.any? { |f| f["type"] == "reject_subscription" } }
    answer = url.frames.reject { |f| f["type"] == "welcome" }
    url.close
    [since, answer]
  end
  REPORT[:not_subjects] = { "list" => %w[ord_1 ord_2], "number" => 5 }.transform_values do |subject|
    frame_answer(port, frame("subscribe", identifier("order_payment", subject: subject)))
  end
  REPORT[:largest_cursor] = frame_answer(
    port, frame("subscribe", identifier("todo", subject: "list_ok", since: 2**53 - 1)),
  )

  # 15e — and the one frame on that list the origin CAN act on, where the
  #       action is nothing: a second identical `subscribe`.
  REPORT[:duplicate_subscribe] = frame_answer(port, SUBSCRIBE_TODO, live: SUBSCRIBE_TODO)

  # 15f — the subscription that duplicate named is untouched. One event emitted
  #       afterwards arrives ONCE, which is what says the second frame neither
  #       tore the subscription down nor replayed its tail.
  dup = connect(port)
  dup.pump_until { dup.frames.any? }
  dup.send_raw(SUBSCRIBE_TODO)
  dup.pump_until { dup.frames.any? { |f| f["type"] == "confirm_subscription" } }
  dup.send_raw(SUBSCRIBE_TODO)
  dup.pump_until(seconds: 2) { false }
  dup_id = Kiosk::Server::Events.emit(topic: :todo, subject: "list_ok", identity_scope: %w[u1],
                                      data: { "done" => true })
  dup.pump_until { dup.messages.any? { |m| m["id"] == dup_id } }
  REPORT[:after_duplicate_subscribed] = dup.messages.count { |m| m["type"] == "subscribed" }
  REPORT[:after_duplicate_delivered] = dup.messages.count { |m| m["id"] == dup_id }
  dup.close

  # 15g — an `unsubscribe` echoing a live subscription's identifier drops it:
  #       an event before it arrives, nothing at all comes after it.
  gone = connect(port)
  gone.pump_until { gone.frames.any? }
  gone.send_raw(SUBSCRIBE_TODO)
  gone.pump_until { gone.frames.any? { |f| f["type"] == "confirm_subscription" } }
  before_id = Kiosk::Server::Events.emit(topic: :todo, subject: "list_ok", identity_scope: %w[u1],
                                         data: { "done" => false })
  gone.pump_until { gone.messages.any? { |m| m["id"] == before_id } }
  REPORT[:before_unsubscribe_delivered] = gone.messages.any? { |m| m["id"] == before_id }
  sent = gone.frames.length
  gone.send_raw(frame("unsubscribe", identifier("todo", subject: "list_ok")))
  gone.pump_until(seconds: 1) { false }
  Kiosk::Server::Events.emit(topic: :todo, subject: "list_ok", identity_scope: %w[u1],
                             data: { "done" => true })
  gone.pump_until(seconds: 2) { false }
  REPORT[:after_unsubscribe_frames] = gone.frames[sent..]
  gone.close

  # 15h — the heartbeat: two consecutive pings on one socket, in beats.
  beat = connect(port)
  ping_wait = 3 * Kiosk::Server::EventsConnection::BEATS_PER_PING * PROBE_BEAT_INTERVAL
  beat.pump_until(seconds: ping_wait) { beat.pings.length >= 2 }
  REPORT[:ping] = beat.pings.first&.last
  REPORT[:ping_gap_beats] =
    beat.pings.length >= 2 ? ((beat.pings[1][0] - beat.pings[0][0]) / PROBE_BEAT_INTERVAL).round : nil
  REPORT[:shipped_beat_interval] = SHIPPED_BEAT_INTERVAL
  beat.close

  # ── re-authorisation while the subscription stands (spec Section 8.5.6) ───
  #
  # Two sockets are opened and HELD while the operator's answers change under
  # them. `held` carries the subject-scoped `consented` subscription, whose
  # reach is withdrawn; `plain` carries a principal one and only reacts to the
  # credential. Both run the same timer, so `plain` staying quiet through the
  # first change is what says the teardown was aimed rather than global.
  held = connect(port, path: "/kiosk/events?topic=todo:list_ok")
  held.pump_until { held.messages.any? { |m| m["type"] == "subscribed" } }
  plain = connect(port, path: "/kiosk/events?topic=order_payment")
  plain.pump_until { plain.messages.any? { |m| m["type"] == "subscribed" } }
  # Two sockets holding NO subscription: one stays idle, one subscribes only
  # after the credential is revoked.
  idle = connect(port)
  idle.pump_until { idle.frames.any? { |f| f["type"] == "welcome" } }
  dormant = connect(port)
  dormant.pump_until { dormant.frames.any? { |f| f["type"] == "welcome" } }

  # 16 — nothing has changed, so several periods later neither socket has been
  #      told anything. A timer that tore a valid subscription down would be as
  #      wrong as one that never ran.
  held.pump_until(seconds: 3) { false }
  plain.pump_until(seconds: 1) { false }
  REPORT[:steady_unsubscribed] = held.messages.any? { |m| m["type"] == "unsubscribed" }
  REPORT[:steady_disconnected] = plain.frames.any? { |f| f["type"] == "disconnect" }

  # 17 — the operator's own rule stops saying yes. Delivery stops and the
  #      client is told why, on the subscription that lost it and no other.
  REACHABLE[:value] = false
  held.pump_until(seconds: 5) { held.messages.any? { |m| m["type"] == "unsubscribed" } }
  REPORT[:reach_revoked_frame] = held.messages.find { |m| m["type"] == "unsubscribed" }
  plain.pump_until(seconds: 2) { false }
  REPORT[:other_socket_unsubscribed] = plain.messages.any? { |m| m["type"] == "unsubscribed" }

  # 18 — the credential stops resolving for a reason that is not expiry. The
  #      whole connection goes, and the client is told that coming back with
  #      this token will not help.
  REVOKED[:value] = true
  dormant.send_raw(frame("subscribe", identifier("todo", subject: "list_ok", since: 0)))
  plain.pump_until(seconds: 5) { plain.frames.any? { |f| f["type"] == "disconnect" } }
  plain.pump_until(seconds: 3) { plain.closed? }
  REPORT[:revoked_socket_closed] = plain.closed?
  # EVERY disconnect frame the socket was sent, collected after it closed:
  # `reconnect` is what a client acts on, so a second frame carrying the
  # opposite flag is the defect, and reading only the first cannot see it.
  REPORT[:revoked_frames] = plain.frames.select { |f| f["type"] == "disconnect" }
  [idle, dormant].each { |sock| sock.pump_until(seconds: 5) { sock.closed? } }
  REPORT[:revoked_idle_frames] = idle.frames.select { |f| f["type"] == "disconnect" }
  REPORT[:revoked_dormant_frames] = dormant.frames.reject { |f| f["type"] == "welcome" }
  [held, plain, idle, dormant].each(&:close)

  # 19 — the access token AGES OUT under a held socket. The two sockets differ
  #      in nothing but their credential's `exp`, and that is what separates
  #      "come back" from "stop". Last, because after it no upgrade resolves.
  REVOKED[:value] = false
  EXPIRES_AT[:value] = Time.now.to_i + 3
  expiring = connect(port, path: "/kiosk/events?topic=order_payment")
  expiring.pump_until { expiring.messages.any? { |m| m["type"] == "subscribed" } }
  expiring_idle = connect(port)
  expiring_idle.pump_until { expiring_idle.frames.any? { |f| f["type"] == "welcome" } }
  expiring.pump_until(seconds: 8) { expiring.frames.any? { |f| f["type"] == "disconnect" } }
  expiring.pump_until(seconds: 3) { expiring.closed? }
  expiring_idle.pump_until(seconds: 5) { expiring_idle.closed? }
  REPORT[:expired_frames] = expiring.frames.select { |f| f["type"] == "disconnect" }
  REPORT[:expired_idle_frames] = expiring_idle.frames.select { |f| f["type"] == "disconnect" }
  [expiring, expiring_idle].each(&:close)

  REPORT[:ok] = true
rescue StandardError => e
  REPORT[:error] = "#{e.class}: #{e.message}"
  REPORT[:backtrace] = e.backtrace&.first(6)
end

puts JSON.generate(REPORT)
exit 0
