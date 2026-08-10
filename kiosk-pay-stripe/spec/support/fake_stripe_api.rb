# frozen_string_literal: true

require "socket"
require "json"
require "uri"

# A tiny STATEFUL Stripe API served over real HTTP, for the K-492 setup-session
# reuse examples.
#
# ## Why this exists rather than a double
# `outstanding_setup_session` can only reuse a session if THREE things line up
# that a `double("SessionList", data: [...])` cannot check, because the double
# replaces every one of them:
#
#   1. the list request actually carries the filters we think it does
#      (`customer=…&status=open`) — a double asserts the literal Ruby args, not
#      what the SDK puts on the wire;
#   2. the JSON that comes back deserializes into objects whose `respond_to?`
#      answers true for `mode` / `success_url` / `url` — `Stripe::StripeObject`
#      answers those through `method_missing`, and the adapter's `field` helper
#      returns nil (⇒ never reuse, silently) for anything it says no to;
#   3. a session that was CREATED is subsequently LISTED — i.e. the round trip,
#      not one call in isolation.
#
# So this fake stores what it is asked to create and honours the `customer` and
# `status` filters on list. Everything between the adapter and this server is
# the real Stripe SDK: real query encoding, real HTTP, real deserialization.
# It is NOT a claim about Stripe's own semantics — only `stripe_integration_spec.rb`
# (real key) can make those. See that file, and the stripe-mock group in
# `stripe_setup_reuse_spec.rb`, for what each layer does and does not prove.
class FakeStripeApi
  Request = Struct.new(:method, :path, :query, :params, keyword_init: true)

  def initialize
    @server    = TCPServer.new("127.0.0.1", 0)
    @requests  = []
    @sessions  = []
    @counter   = 0
    @mutex     = Mutex.new
    @thread    = Thread.new { accept_loop }
    @thread.abort_on_exception = false
  end

  def base_url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @thread&.kill
    @server.close
  rescue IOError
    nil
  end

  # Every request the SDK made, in order.
  def requests
    @mutex.synchronize { @requests.dup }
  end

  def requests_to(method, path)
    requests.select { |r| r.method == method && r.path == path }
  end

  # Flip every stored session out of `open`, as Stripe does once the human
  # completes (or lets expire) the hosted page.
  def close_all_sessions!
    @mutex.synchronize { @sessions.each { |s| s[:status] = "complete" } }
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      handle(socket)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(socket)
    request_line = socket.gets
    return socket.close if request_line.nil?

    method, target, = request_line.split(" ")
    path, query = target.split("?", 2)
    headers = read_headers(socket)
    body    = headers["content-length"] ? socket.read(headers["content-length"].to_i).to_s : ""

    params = form_params(query.to_s.empty? ? body : query)
    @mutex.synchronize do
      @requests << Request.new(method: method, path: path, query: query.to_s, params: params)
    end

    respond(socket, route(method, path, params))
  ensure
    begin
      socket.close
    rescue StandardError
      nil
    end
  end

  def read_headers(socket)
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.to_s.downcase] = value.to_s.strip
    end
    headers
  end

  def form_params(encoded)
    URI.decode_www_form(encoded.to_s).to_h
  rescue ArgumentError
    {}
  end

  def route(method, path, params)
    case [method, path]
    when %w[POST /v1/customers]        then create_customer
    when %w[POST /v1/checkout/sessions] then create_session(params)
    when %w[GET /v1/checkout/sessions]  then list_sessions(params)
    else { object: "error", error: { message: "fake: unrouted #{method} #{path}" } }
    end
  end

  def create_customer
    { id: "cus_fake_#{next_id}", object: "customer" }
  end

  def create_session(params)
    id      = "cs_test_fake#{next_id}"
    session = {
      id:          id,
      object:      "checkout.session",
      mode:        params["mode"],
      customer:    params["customer"],
      success_url: params["success_url"],
      status:      "open",
      url:         "https://checkout.stripe.com/c/pay/#{id}",
    }
    @mutex.synchronize { @sessions << session }
    session
  end

  # Honours the two filters the adapter relies on. A code change that stopped
  # sending `status=open`, or sent a different customer, changes what comes back
  # here — which is the whole point of filtering rather than echoing.
  def list_sessions(params)
    matched = @mutex.synchronize do
      @sessions.select do |s|
        (params["customer"].nil? || s[:customer] == params["customer"]) &&
          (params["status"].nil? || s[:status] == params["status"])
      end
    end
    limit = params["limit"].to_i
    matched = matched.first(limit) if limit.positive?
    { object: "list", url: "/v1/checkout/sessions", has_more: false, data: matched }
  end

  def next_id
    @counter += 1
  end

  def respond(socket, payload)
    json = JSON.generate(payload)
    socket.print(
      "HTTP/1.1 200 OK\r\n" \
      "Content-Type: application/json\r\n" \
      "Content-Length: #{json.bytesize}\r\n" \
      "Connection: close\r\n\r\n#{json}",
    )
  end
end
