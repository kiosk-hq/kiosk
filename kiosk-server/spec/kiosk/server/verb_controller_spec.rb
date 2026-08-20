# frozen_string_literal: true

# THE 0.4 PER-VERB WIRE at the wire level (T-068 slices 1 and 2, T-074 = A).
#
# `GET <endpoint>/<query-name>` and `POST <endpoint>/<action-name>`, resolved
# against the same registry `GET <endpoint>/schema` renders its descriptors
# from. The argument ENCODING is unit-tested next door in
# `argument_decoder_spec.rb`; what is proved here is that a real request
# reaches it, that the answer is the handler's payload VERBATIM, that a
# refusal comes back as an RFC 9457 problem document (T-072 = C), and — in the
# last block — that this is now the ONLY way to reach an operator verb,
# because the cutover DELETED `POST /kiosk/{query,run}` outright.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host, so `path_parameters` is set by hand exactly as the
# router would.

require "rack/mock"
require "json"

RSpec.describe Kiosk::Server::VerbController do
  let(:connection) { FakeConnection.new }

  before do
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = "https://demo.example"
      c.roles       = %i[customer]
      c.agent_idp   = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
    end
    # No database in the gem's own env; SessionContext only needs a connection
    # that answers #transaction and #exec_query.
    allow_any_instance_of(described_class).to receive(:connection_for).and_return(connection)
  end

  def token
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
      audience: "https://demo.example",
    )
  end

  # One per-verb request. `action` is :show for a GET, :create for a POST;
  # `kiosk_verb` is the path segment the router would have captured.
  def call_verb(method, name, query: nil, body: nil, auth: true, accept: nil)
    path   = "/kiosk/#{name}#{query ? "?#{query}" : ""}"
    action = method == :get ? :show : :create
    opts   = { method: method.to_s.upcase }
    if body
      opts[:input] = body
      opts["CONTENT_TYPE"] = "application/json"
    end
    opts["HTTP_AUTHORIZATION"] = "Bearer #{token}" if auth
    # Rack::MockRequest sends no `Accept` by default; a real assistant does,
    # and it is the input Rails' `_set_vary_header` keys off (K-823).
    opts["HTTP_ACCEPT"] = accept if accept

    env = Rack::MockRequest.env_for(path, **opts)
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/verb", action: action.to_s, kiosk_verb: name }

    dispatch(described_class, action, env)
  end

  # Returns [status, parsed body, headers] — the headers matter now: the media
  # type is half of what makes a problem document one, and the cache policy is
  # response shape (design §3.3).
  def dispatch(controller, action, env)
    status, headers, body = controller.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    @last_headers = headers
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true), headers]
  end

  def last_headers = @last_headers

  # A query whose handler reports back what it was actually handed, so an
  # assertion about coercion is an assertion about what the HANDLER sees —
  # not about what the decoder returned.
  def declare_echo(input_schema)
    declare_query("echo", input_schema: input_schema) do
      render json: [{
        min_stars: params[:min_stars],
        klass:     params[:min_stars].class.name,
        amenity:   params[:amenity],
        seen:      params.to_unsafe_h.keys.sort,
      }]
    end
  end

  describe "a query is a GET at its own path" do
    before { declare_query("salons") { render json: [{ id: 1, name: "Combette on Park" }] } }

    it "answers with the handler's payload VERBATIM — a bare array, no envelope" do
      status, body = call_verb(:get, "salons")
      expect(status).to eq(200)
      expect(body).to eq([{ id: 1, name: "Combette on Park" }])
    end

    it "carries the cache policy every wire response must carry" do
      call_verb(:get, "salons")
      expect(last_headers["Vary"]).to eq("Authorization, Kiosk-PoW")
      expect(last_headers["Cache-Control"]).to eq("private, no-store")
    end

    it "answers 401 before it will say whether the verb exists" do
      # Design §3.5 lists the declared-verb check BEFORE authentication;
      # this controller resolves identity first, so an unauthenticated probe
      # cannot tell a registered name from an unregistered one. That is
      # ordinary gate ORDER, not an anti-enumeration defence — spec §4.2 and
      # {VerbController}'s own comment record that warrant as RETIRED, because
      # `GET <endpoint>/schema` is public and publishes the whole catalog to
      # anyone who asks. Both answer 401 here.
      expect(call_verb(:get, "salons",     auth: false).first).to eq(401)
      expect(call_verb(:get, "frobnicate", auth: false).first).to eq(401)
    end

    it "answers an unknown name a problem document, naming what IS registered" do
      status, body = call_verb(:get, "frobnicate")
      expect(status).to eq(404)
      expect(last_headers["Content-Type"]).to include("application/problem+json")
      expect(body[:type]).to   eq("https://kiosk.tech/problems/not_found")
      expect(body[:title]).to  eq("Not found")
      expect(body[:status]).to eq(404)
      expect(body[:code]).to   eq("not_found")
      expect(body[:hint]).to   include("salons")
    end
  end

  describe "an action is a POST at its own path" do
    before do
      declare_action("book_appointment") do
        render json: { appointment_id: 7, salon_id: params[:salon_id] }
      end
    end

    it "answers with the handler's object VERBATIM — no `value` wrapper" do
      status, body = call_verb(:post, "book_appointment", body: JSON.generate(salon_id: 3))
      expect(status).to eq(200)
      expect(body).to eq(appointment_id: 7, salon_id: 3)
    end
  end

  # RFC 8288 (T-092). A paginating query stopped being a shape: the body is the
  # bare array every query answers and the two page facts are response headers.
  describe "a paginating query answers a bare array with Link + X-Total-Count" do
    let(:cursor) { Kiosk::Server::Cursor.encode_offset(20) }

    it "puts the next page in a Link header with rel=next, not in the body" do
      declare_query("listings") do
        render_kiosk_page([{ id: 1 }], next_cursor: Kiosk::Server::Cursor.encode_offset(20))
      end
      status, body = call_verb(:get, "listings", query: "limit=1")
      expect(status).to eq(200)
      expect(body).to eq([{ id: 1 }])
      expect(last_headers["Link"])
        .to eq(%(<http://example.org/kiosk/listings?limit=1&cursor=#{cursor}>; rel="next"))
    end

    # §8.4 (matrix SPEC-088). RFC 8288 PERMITS a relative target resolved
    # against the request URI; the spec's SHOULD is that an operator send an
    # ABSOLUTE one, because an assistant is told to fetch the target VERBATIM
    # and a verbatim fetch of `?limit=1&cursor=…` is not a fetch of anything.
    # The example above pins the whole string, which would also catch this —
    # but only as a side effect of pinning a literal, so the requirement is
    # asserted here in its own terms: scheme + authority present, and the
    # target resolves to ITSELF (the definition of an absolute reference).
    it "sends an ABSOLUTE Link target — fetchable verbatim, no resolution step" do
      declare_query("listings") do
        render_kiosk_page([{ id: 1 }], next_cursor: Kiosk::Server::Cursor.encode_offset(20))
      end
      call_verb(:get, "listings", query: "limit=1")

      target = last_headers["Link"][/<([^>]*)>/, 1]
      uri    = URI.parse(target)
      expect(uri).to be_absolute
      expect(uri.scheme).to eq("http")
      expect(uri.host).to   eq("example.org")
      # An absolute reference is its own resolution against any base.
      expect(URI.join("http://elsewhere.invalid/deep/path", target).to_s).to eq(target)
    end

    it "replaces an incoming cursor rather than appending a second one" do
      declare_query("listings") do
        render_kiosk_page([{ id: 1 }], next_cursor: Kiosk::Server::Cursor.encode_offset(20))
      end
      call_verb(:get, "listings", query: "limit=1&cursor=b2Zmc2V0OjEw&min_stars=4")
      expect(last_headers["Link"]).to eq(
        %(<http://example.org/kiosk/listings?limit=1&min_stars=4&cursor=#{cursor}>; rel="next"),
      )
    end

    it "sends NO Link on the last page — its absence is what completeness means" do
      declare_query("listings") { render_kiosk_page([{ id: 1 }]) }
      _status, body = call_verb(:get, "listings")
      expect(body).to eq([{ id: 1 }])
      expect(last_headers["Link"]).to be_nil
    end

    # The total is the handler's to state on a truncated page, and the wire's
    # to derive on a complete one. It is never guessed from the page.
    it "emits the handler's total on a truncated page" do
      declare_query("listings") do
        render_kiosk_page([{ id: 1 }], next_cursor: Kiosk::Server::Cursor.encode_offset(20),
                                       total:       97)
      end
      call_verb(:get, "listings")
      expect(last_headers["X-Total-Count"]).to eq("97")
    end

    it "omits X-Total-Count on a truncated page whose handler gave no total" do
      declare_query("listings") do
        render_kiosk_page([{ id: 1 }], next_cursor: Kiosk::Server::Cursor.encode_offset(20))
      end
      call_verb(:get, "listings")
      expect(last_headers["X-Total-Count"]).to be_nil
    end

    it "derives X-Total-Count from a COMPLETE array answer, paginating or not" do
      declare_query("salons") { render json: [{ id: 1 }, { id: 2 }] }
      call_verb(:get, "salons")
      expect(last_headers["X-Total-Count"]).to eq("2")
    end

    it "sends neither header for an action" do
      declare_action("book_appointment") { render json: { ok: 1 } }
      call_verb(:post, "book_appointment", body: "{}")
      expect(last_headers["Link"]).to be_nil
      expect(last_headers["X-Total-Count"]).to be_nil
    end

    # §3.3 rule 3/4: a page is a per-caller answer. Nothing about adopting a
    # cacheable-looking `Link` header may relax that.
    it "is still private, no-store — a page is never shared-cacheable" do
      declare_query("listings") do
        render_kiosk_page([{ id: 1 }], next_cursor: Kiosk::Server::Cursor.encode_offset(20))
      end
      call_verb(:get, "listings")
      expect(last_headers["Cache-Control"]).to eq("private, no-store")
      expect(last_headers["Vary"]).to eq("Authorization, Kiosk-PoW")
    end
  end

  # §3.7.3 (matrix SPEC-013), a MUST-NOT: `public` or `s-maxage` on a verb
  # response hands an identity-scoped answer to a SHARED cache, which is one
  # agent reading another agent's rows. The reference has never emitted
  # either, and that is exactly the kind of fact that stays true until it
  # quietly does not.
  #
  # THE ABSENCE IS ASSERTED ACROSS EVERY STATUS THIS PLANE PRODUCES, because
  # the directive is written by three different branches of
  # {Headers.add_cache_policy}: the 200 default, the operator-relaxed 200, and
  # the forced `no-store` on a 402/4xx.
  #
  # AND IT CARRIES ITS OWN POSITIVE CONTROL, in the last example: the SAME
  # grep run against `GET <endpoint>/schema`, the one endpoint under the mount
  # that is public on purpose, FINDS `public` there. Without it, "no verb
  # response says public" would pass just as well on a build where nothing
  # anywhere could ever say it.
  describe "no verb response is shared-cacheable (§3.7.3)" do
    # The refusal LOGS the value it refused, which is the point of it — but
    # these examples trigger it on purpose, so the operator warning is silenced
    # here rather than printed five times into a green suite. That the line is
    # emitted at all, once, naming the value, is asserted in headers_spec.
    before { allow(Kiosk::Server::Headers).to receive(:warn) }

    def expect_no_shared_caching(cache_control)
      expect(cache_control.to_s).not_to match(/\bpublic\b/)
      expect(cache_control.to_s).not_to match(/\bs-maxage\b/)
    end

    it "not on a 200" do
      declare_query("salons") { render json: [{ id: 1 }] }
      expect(call_verb(:get, "salons").first).to eq(200)
      expect_no_shared_caching(last_headers["Cache-Control"])
    end

    it "not even when the handler tried to set a policy of its own" do
      # Since K-823 a handler's `Cache-Control` DOES reach the wire (see the
      # block below), so this is no longer true by accident — the value is
      # carried out of the sub-dispatch and then REFUSED by
      # {Headers.add_cache_policy}, which is the only place a wire cache
      # policy is decided. Refused, not edited: `public, s-maxage=600` does
      # not become `private, max-age=600`, because nobody wrote that.
      declare_query("salons") do
        response.headers["Cache-Control"] = "public, s-maxage=600"
        render json: [{ id: 1 }]
      end
      call_verb(:get, "salons")
      expect_no_shared_caching(last_headers["Cache-Control"])
      expect(last_headers["Cache-Control"]).to eq("private, no-store")
    end

    it "not when only `public` is named, and not when only `s-maxage` is" do
      # Each directive on its own — a regex that only matched the pair, or
      # only the exact string the example above sends, would pass that example
      # and let either half through alone.
      ["public", "s-maxage=600", "PUBLIC, max-age=30", "max-age=30, s-maxage=90"]
        .each do |policy|
          declare_query("salons") do
            response.headers["Cache-Control"] = policy
            render json: [{ id: 1 }]
          end
          call_verb(:get, "salons")
          expect(last_headers["Cache-Control"]).to eq("private, no-store"), policy
        end
    end

    it "not on a refusal" do
      declare_query("salons", input_schema: { type: "object", additionalProperties: false,
                                              properties: {}, required: [] }) { render json: [] }
      expect(call_verb(:get, "salons", query: "nope=1").first).to eq(400)
      expect_no_shared_caching(last_headers["Cache-Control"])
    end

    it "…while GET <endpoint>/schema, which IS public, says so — the control" do
      declare_query("salons") { render json: [] }
      env = Rack::MockRequest.env_for("/kiosk/schema")
      status, headers, = Kiosk::Server::WireController.action(:schema).call(env)
      expect(status).to eq(200)
      expect(headers["Cache-Control"]).to match(/\bpublic\b/)
    end
  end

  # §3.7.4 (matrix SPEC-016), the neighbouring MAY: "the default for a `200`
  # is `private, no-store`; an operator MAY relax it to `private, max-age=N`
  # for a genuinely identity-independent payload". K-823: that permission was
  # UNREACHABLE — {HandlerDispatch} read `status, _headers, body` and dropped
  # the sub-response's headers, so the only code an operator writes on this
  # wire could not exercise the only cache permission the spec grants them.
  # {Headers.add_cache_policy}'s "an operator who has already set one keeps
  # it" branch was unit-tested and could not be reached through a request.
  describe "an operator MAY relax a 200's cache policy from a handler (§3.7.4)" do
    it "keeps `private, max-age=N` the handler set" do
      declare_query("salons") do
        response.headers["Cache-Control"] = "private, max-age=600"
        render json: [{ id: 1 }]
      end
      expect(call_verb(:get, "salons").first).to eq(200)
      # SPELLED THE WAY IT IS EMITTED, not the way the handler wrote it:
      # ActionDispatch parses `Cache-Control` and REGENERATES it on commit in
      # its own directive order, so `private, max-age=600` leaves as
      # `max-age=600, private`. Same directives, and RFC 9111 gives their
      # order no meaning — {Headers::PUBLIC_SHORT} is written in that order
      # for the same reason.
      expect(last_headers["Cache-Control"]).to eq("max-age=600, private")
    end

    it "and the default still applies to a handler that sets nothing" do
      declare_query("salons") { render json: [{ id: 1 }] }
      call_verb(:get, "salons")
      expect(last_headers["Cache-Control"]).to eq("private, no-store")
    end

    it "on an ACTION as well as a query" do
      declare_action("book_appointment") do
        response.headers["Cache-Control"] = "private, max-age=30"
        render json: { id: 1 }
      end
      expect(call_verb(:post, "book_appointment", body: "{}").first).to eq(200)
      expect(last_headers["Cache-Control"]).to eq("max-age=30, private")
    end

    it "NOT on a refusal: a 4xx keeps the wire's own policy" do
      # §3.7.4 speaks about a `200`, and {HandlerDispatch} only publishes the
      # sub-response's headers on a 2xx. A handler that renders 403 with a
      # long freshness would otherwise make its own refusal cacheable.
      declare_query("salons") do
        response.headers["Cache-Control"] = "private, max-age=600"
        render json: { error: { code: "forbidden", message: "no" } }, status: 403
      end
      expect(call_verb(:get, "salons").first).to eq(403)
      expect(last_headers["Cache-Control"]).to eq("private, no-store")
    end

    # WHY THE PROPAGATION LIST HAS EXACTLY ONE ENTRY, measured rather than
    # asserted. The sub-request is built from the wire request, `HTTP_ACCEPT`
    # included, so Rails' own `_set_vary_header` stamps `Vary: Accept` on the
    # handler's render. A blanket copy of the sub-response's headers would
    # import that onto the wire, where it is false — the answer is JSON
    # whatever the caller asked for — and would split a cache by Accept string
    # for nothing. The first expectation proves Rails really does it; the
    # second proves the seam does not carry it.
    it "does not carry the `Vary` Rails synthesises on the sub-render" do
      seen = nil
      declare_query("salons") do
        render json: [{ id: 1 }]
        seen = response.headers["Vary"]
      end
      call_verb(:get, "salons", accept: "application/json")
      expect(seen).to eq("Accept")
      expect(last_headers["Vary"]).to eq("Authorization, Kiosk-PoW")
    end
  end

  describe "the HTTP method carries the read/write semantics" do
    before do
      declare_query("salons") { render json: [] }
      declare_action("book_appointment") { render json: {} }
    end

    # Slice 1 answered these 404 because 405 was not in the closed vocabulary
    # and adding a code is spec-first. Slice 2 is that spec change: the
    # resource EXISTS and refuses the method, which is what 405 means, and
    # RFC 9110 §15.5.6 makes `Allow` mandatory on one.
    it "answers a GET at an ACTION's name 405, with Allow: POST" do
      status, body = call_verb(:get, "book_appointment")
      expect(status).to eq(405)
      expect(last_headers["Allow"]).to eq("POST")
      expect(body[:code]).to   eq("method_not_allowed")
      expect(body[:type]).to   eq("https://kiosk.tech/problems/method_not_allowed")
      expect(body[:detail]).to include("is an action, not a query")
      expect(body[:hint]).to   include("POST /kiosk/book_appointment")
    end

    it "answers a POST at a QUERY's name 405, with Allow: GET" do
      status, body = call_verb(:post, "salons", body: "{}")
      expect(status).to eq(405)
      expect(last_headers["Allow"]).to eq("GET")
      expect(body[:code]).to   eq("method_not_allowed")
      expect(body[:detail]).to include("is a query, not an action")
      expect(body[:hint]).to   include("GET /kiosk/salons")
    end
  end

  describe "arguments reach the handler with their declared types" do
    before do
      declare_echo(type: "object", additionalProperties: false,
                   properties: { min_stars: { type: "integer" },
                                 amenity:   { type: "array", items: { type: "string" } } })
    end

    it "hands the handler an Integer, not the query string's String" do
      _status, body = call_verb(:get, "echo", query: "min_stars=4")
      expect(body.first[:min_stars]).to eq(4)
      expect(body.first[:klass]).to eq("Integer")
    end

    it "decodes the percent-encoded and the raw bracket spellings identically" do
      _s1, percent = call_verb(:get, "echo", query: "amenity%5B%5D=pool&amenity%5B%5D=spa")
      _s2, raw     = call_verb(:get, "echo", query: "amenity[]=pool&amenity[]=spa")
      expect(percent.first[:amenity]).to eq(%w[pool spa])
      expect(raw).to eq(percent)
    end

    it "refuses a value that will not coerce with a 400 naming the parameter" do
      status, body = call_verb(:get, "echo", query: "min_stars=four")
      expect(status).to eq(400)
      expect(body[:code]).to   eq("bad_request")
      expect(body[:detail]).to include("min_stars")
    end

    it "refuses a shape a query cannot carry with a 400 that names the ACTION remedy" do
      status, body = call_verb(:get, "echo", query: "price%5Brange%5D%5Bmin%5D=1")
      expect(status).to eq(400)
      expect(body[:detail]).to include("price")
      expect(body[:hint]).to   include("ACTION")
    end

    it "does not read a query string on a POST — an action's arguments are its body" do
      declare_action("noop") { render json: { seen: params.to_unsafe_h.keys.sort } }
      _status, body = call_verb(:post, "noop", query: "sneaky=1", body: "{}")
      expect(body[:seen]).not_to include("sneaky")
    end
  end

  # T-068 SLICE 3. `validate_requests` is deliberately NOT set anywhere in this
  # block — it defaults to false, and every example below still gets its 400.
  # That is the slice-3 change: `input_schema` is REQUIRED on every 0.4 verb
  # (T-073 = A) and §8.1 item 5 makes the operator coerce-then-validate before
  # the handler sees an argument, so a per-verb endpoint that validated only
  # behind a flag would be non-conformant with the flag off — and K-717's typed
  # 400 would fall out of the schema layer on some origins and not others.
  describe "input_schema is executable UNCONDITIONALLY on the per-verb wire" do
    it "validates with validate_requests OFF — the flag no longer gates arguments" do
      expect(Kiosk.configuration.validate_requests).to be(false)

      declare_query("catalog", input_schema: { type: "object", additionalProperties: false,
                                               properties: {}, required: [] }) { render json: [] }
      status, body = call_verb(:get, "catalog", query: "nope=1")
      expect(status).to eq(400)
      expect(body[:code]).to   eq("bad_request")
      expect(body[:detail]).to include("nope")
    end

    it "accepts limit and cursor on a verb that declares neither, with a CLOSED schema" do
      # T-070 rule (7). getgrocery's `catalog` is exactly this schema, and
      # without the reserved rule the `?limit=` the pagination contract
      # invites would 400 as a disallowed additional property.
      declare_query("catalog", input_schema: { type: "object", additionalProperties: false,
                                               properties: {}, required: [] }) do
        render json: []
      end
      expect(call_verb(:get, "catalog", query: "limit=20&cursor=eyJvIjoyMH0").first).to eq(200)
    end

    it "refuses a value outside a declared enum — K-717's schema half" do
      declare_query("availability", input_schema: {
                      type: "object", additionalProperties: false,
                      properties: { time: { type: "string", enum: %w[18:00 20:00] } },
                    }) { render json: [] }

      status, body = call_verb(:get, "availability", query: "time=19:00")
      expect(status).to eq(400)
      expect(body[:code]).to   eq("bad_request")
      expect(body[:detail]).to include("time")
      # §9.1 rule 1 (matrix SPEC-103) is TWO statements, and only the first was
      # asserted here: the status, AND that the answer NAMES THE VALID VALUES.
      # The naming half is the whole recovery path — an assistant that guessed
      # `19:00` can retry correctly from this sentence alone, without re-fetching
      # the catalogue. Naming only the parameter tells it which argument it got
      # wrong and nothing about what would have been right.
      expect(body[:detail]).to include("18:00").and include("20:00")
      # …and the value it actually sent is NOT among them — a `detail` that
      # simply echoed the request would satisfy the line above by accident.
      expect(body[:detail]).not_to include("19:00")
    end

    it "still refuses an undeclared parameter under additionalProperties: false" do
      declare_query("catalog", input_schema: { type: "object", additionalProperties: false,
                                               properties: {}, required: [] }) { render json: [] }
      status, body = call_verb(:get, "catalog", query: "nope=1")
      expect(status).to eq(400)
      expect(body[:detail]).to include("nope")
    end
  end

  # THE HARD CUT (T-074 = A). While the per-verb wire was being built this
  # block proved the OPPOSITE of what it proves now: that `POST
  # <endpoint>/query` still answered, that both wires agreed on the payload,
  # that the old one still spoke the 0.3 error envelope, and that one PoW
  # proof was spendable on either. All four were true on purpose — cutting the
  # multiplexed pair mid-build would have broken the eight demos — and all
  # four are false on purpose now. What replaces them is the deletion itself:
  # no action, no route, and nothing privileged left at the path.
  # A body that is not JSON at all never reaches Kiosk's own parse guard on
  # this wire: `serve` reads `params[:kiosk_verb]` first, and touching `params`
  # makes Rails parse the body — so the raise comes out of the PARAMETER layer.
  # Without the `rescue_from ActionDispatch::Http::Parameters::ParseError` in
  # {WireController} it escapes to the host's exception app, which renders an
  # HTML or plain-text 400 with no `code`: the one hole in an error contract
  # that is otherwise problem documents all the way down.
  describe "a malformed request body" do
    before { declare_action("place_order") { render json: { ok: 1 } } }

    it "is a bad_request problem document, not the host's generic 400" do
      status, problem = call_verb(:post, "place_order", body: "{not valid json")

      expect(status).to eq(400)
      expect(last_headers["Content-Type"]).to include("application/problem+json")
      expect(problem[:code]).to   eq("bad_request")
      expect(problem[:type]).to   eq("https://kiosk.tech/problems/bad_request")
      expect(problem[:status]).to eq(400)
      expect(problem[:detail]).to include("invalid JSON body")
      expect(problem[:hint]).to   include("query string")
    end
  end

  describe "the 0.3 wire is GONE — one wire, one conformance surface" do
    before { declare_query("salons") { render json: [{ id: 1 }] } }

    it "leaves WireController with exactly two actions — schema and pay" do
      actions = Kiosk::Server::WireController.action_methods.to_a

      expect(actions).to match_array(%w[schema pay])
      expect(actions).not_to include("query", "run")
      expect(Kiosk::Server::WireController.instance_methods(false)).not_to include(:query, :run)
    end

    it "draws no /query and no /run — the route table has no such paths" do
      routes = Kiosk::Server::Engine.routes
      routes.finalize!
      paths = routes.routes.map { |route| route.path.spec.to_s }

      # The two RESERVED endpoints are still literally drawn…
      expect(paths).to include("/schema(.:format)", "/pay(.:format)")
      # …and the multiplexed pair is not drawn at all: not as a route, not as
      # a tombstone. The only thing that can match those paths now is the
      # constrained per-verb pair at the bottom of the table.
      expect(paths.grep(%r{\A/(query|run)\b})).to be_empty
      expect(paths.last(2)).to eq(["/:kiosk_verb(.:format)", "/:kiosk_verb(.:format)"])
    end

    it "answers POST <endpoint>/query as the VERB named `query` — 404, nobody registered one" do
      # The sharpest statement of the cut. The path still resolves, but it
      # resolves through the SAME constrained per-verb pair every other name
      # goes through, and answers the ordinary `not_found` problem document
      # naming what IS registered. There is no privileged 0.3 endpoint left
      # here — `query` is now just a name an operator has not used.
      status, body, headers = call_verb(:post, "query", body: JSON.generate(name: "salons"))

      expect(status).to eq(404)
      expect(headers["Content-Type"]).to include("application/problem+json")
      expect(body[:type]).to   eq("https://kiosk.tech/problems/not_found")
      expect(body[:status]).to eq(404)
      expect(body[:code]).to   eq("not_found")
      # Not the 0.3 envelope, and not a hint that the old wire moved: the
      # answer is indistinguishable from any other unregistered action.
      expect(body).not_to have_key(:ok)
      expect(body).not_to have_key(:error)
      expect(JSON.generate(body)).not_to include("0.3")
    end

    it "answers POST <endpoint>/run the same way — one unregistered name among others" do
      status, body, headers = call_verb(:post, "run", body: "{}")

      expect(status).to eq(404)
      expect(headers["Content-Type"]).to include("application/problem+json")
      expect(body[:code]).to eq("not_found")
      expect(body).not_to have_key(:ok)
    end

    it "leaves both names REGISTRABLE — they stopped being reserved with the routes that named them" do
      # `RESERVED_NAMES` is the engine's drawn first segments, and `query`/`run`
      # are no longer among them (`bin/check-kiosk-names` holds the two sides
      # equal). So an operator may now declare a verb called `query`, and it is
      # served at `<endpoint>/query` like any other.
      expect(Kiosk::Server::HandlerMixin::RESERVED_NAMES).to eq(%w[agents auth oauth pay schema])

      declare_action("query") { render json: { queued: 1 } }
      status, body = call_verb(:post, "query", body: "{}")

      expect(status).to eq(200)
      expect(body).to eq(queued: 1)
    end

    it "fingerprints a call from the METHOD and the PATH SEGMENT (§3.4), not from a body field" do
      # 0.3 could not say this: every read was multiplexed through one POST,
      # so the method was a constant and the verb name had to be smuggled back
      # INTO the arguments to reach the digest. Reproducing that digest byte
      # for byte was the only reason one proof was spendable on either wire,
      # and only one is served now.
      seen = []
      allow(Kiosk::Server::PowGate).to receive(:gate) { |**kwargs| seen << kwargs.slice(:method, :verb, :body) }

      call_verb(:get, "salons", query: "city=Lisbon")

      expect(seen).to eq([{ method: "GET", verb: "salons", body: { city: "Lisbon" } }])
    end
  end
end
