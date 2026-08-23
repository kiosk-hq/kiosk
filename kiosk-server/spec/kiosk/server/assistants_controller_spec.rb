# frozen_string_literal: true

# The «Link an assistant» engine page: session-authed listing of
# bound assistant accounts + mint/unlink, HTML shim over LinkCode /
# AccountBinding. Same Metal-dispatch harness as the other controller specs.

require "rack/mock"
require "openssl"

RSpec.describe "AssistantsController" do
  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }
  let(:human)   { build_identity(actor: "human", agent_id: nil, user_id: user_id) }
  let(:pem)     { OpenSSL::PKey::RSA.generate(2048).public_key.to_pem }
  # `next_exec_result: []` — an empty listing unless an example says otherwise.
  # The fake's default row exists for the Executor's `INSERT … RETURNING id`;
  # handing it to this page's listing SELECT would present a row with no
  # public_key.
  let(:con)     { FakeConnection.new(next_exec_result: []) }
  let(:session) { {} }

  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  before do
    Kiosk.configure do |c|
      c.issuer                     = "https://provider.example"
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
    wire_user_idp(human)
    ar_base = class_double("ActiveRecord::Base").as_stubbed_const
    allow(ar_base).to receive(:lease_connection).and_return(con)
    allow(con).to receive(:quote).and_call_original
  end

  def dispatch(action, method:, params: {}, headers: {})
    path = action == :show ? "" : "/#{action}"
    env = Rack::MockRequest.env_for(
      "https://provider.example/kiosk/auth/assistants#{path}",
      method: method, params: params,
    )
    headers.each { |k, v| env[k] = v }
    env["rack.session"] = session
    status, response_headers, body = Kiosk::Server::AssistantsController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, raw, response_headers]
  end

  # Default config wires no sign_in_path → the engine keeps its neutral bare
  # 401 (unchanged API contract). A browser Accept header does NOT change this.
  it "401s without a provider session when no sign_in_path is configured" do
    wire_user_idp(nil)
    status, body = dispatch(:show, method: "GET", headers: { "HTTP_ACCEPT" => "text/html" })
    expect(status).to eq(401)
    expect(body).to include("Sign in")
  end

  # MANAGE-PAGE-UNAUTH-UX: with a sign_in_path wired AND a browser (HTML)
  # request, an unauthenticated visitor is redirected to the operator's
  # sign-in — not shown a bare 401 — with a flash alert and a stored return-to.
  context "with config.sign_in_path set (browser UX)" do
    before do
      wire_user_idp(nil)
      Kiosk.configure { |c| c.sign_in_path = "/users/sign_in" }
    end

    it "redirects an unauthenticated HTML request to the sign-in path (302) and stores return-to" do
      status, _body, headers = dispatch(
        :show, method: "GET", headers: { "HTTP_ACCEPT" => "text/html" },
      )
      expect(status).to eq(302)
      expect(headers["Location"]).to end_with("/users/sign_in")
      # Devise-convention return-to so the visitor lands back on the manage page.
      expect(session["user_return_to"]).to eq("/kiosk/auth/assistants")
    end

    # The flash mixin needs the flash MIDDLEWARE (present in a real Rails app;
    # absent in this bare Metal dispatch), so we assert the controller ATTEMPTS
    # to set the alert rather than reading it back out of a serialised session.
    # The demos' `demo:binding` exercises the real middleware end-to-end.
    it "sets a flash alert telling the visitor to sign in" do
      flash_double = {}
      allow_any_instance_of(Kiosk::Server::AssistantsController)
        .to receive(:flash).and_return(flash_double)
      dispatch(:show, method: "GET", headers: { "HTTP_ACCEPT" => "text/html" })
      expect(flash_double[:alert]).to eq("Please sign in to manage your linked assistants.")
    end

    # Backward compat: a JSON / API caller still gets the plain 401 even with a
    # sign_in_path configured — the redirect is HTML-only.
    it "still 401s a non-HTML (API/JSON) request" do
      status, body, _headers = dispatch(
        :show, method: "GET", headers: { "HTTP_ACCEPT" => "application/json" },
      )
      expect(status).to eq(401)
      expect(body).to include("Sign in")
    end
  end

  it "lists the holder's bound assistant accounts with key fingerprints" do
    con.next_exec_result = [
      { "id" => "agent-1", "public_key" => pem, "created_at" => "2026-07-17 12:00:00+00" },
    ]
    status, html = dispatch(:show, method: "GET")

    expect(status).to eq(200)
    expect(html).to include("Linked assistant accounts")
    expect(html).to include(Kiosk::Server::SigningKey.from_pem(pem).kid)
    expect(html).to include(%(value="agent-1"))
    # The SELECT is scoped to the session holder's live rows — through a bind
    # (K-782), so the holder's id is nowhere in the statement text.
    select, binds = con.bound(/SELECT/i).first
    expect(select).to include("WHERE user_id = $1")
    expect(select).to include("revoked_at IS NULL")
    expect(binds).to eq([user_id])
    expect(con.all_sql).not_to include(user_id)
    expect(con).not_to have_received(:quote)
  end

  it "mints a link code and shows it exactly once" do
    status, html = dispatch(:link, method: "POST")

    expect(status).to eq(200)
    expect(html).to include("Your link code")
    row_hashes = store.find_by_device_code_hash(
      Kiosk::Server::DeviceAuthorization.hash_device_code(html[%r{<code>([^<]+)</code>}, 1]),
    )
    expect(row_hashes).to be_approved
    expect(row_hashes.user_id).to eq(user_id)
  end

  # roles-from-IdP (ADR-0011 Path A) on the BROWSER path (K-995). The page is
  # the account-binding link ceremony, so the human's IdP role must reach the
  # link row exactly as `AuthController#link` puts it there for the JSON
  # endpoint — otherwise the ceremony's outcome depends on which door the human
  # walked through. Read out of the STORE, not off a message expectation: what
  # matters is the row the assistant will redeem.
  describe "roles-from-IdP on the browser mint (ADR-0011 Path A)" do
    def minted_row(html)
      store.find_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(html[%r{<code>([^<]+)</code>}, 1]),
      )
    end

    it "stamps the signed-in human's role onto the link row" do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      wire_user_idp(build_identity(actor: "human", agent_id: nil, user_id: user_id, role: "owner"))

      _status, html = dispatch(:link, method: "POST")

      expect(minted_row(html).requested_role).to eq("owner")
    end

    # No-regression clause of the ADR amendment: a role-less `user_idp` reports
    # nil and the binding falls back to `registration_role`/absent. `nil` must
    # stay nil on the row — not the empty string, which `validated_role` would
    # have to special-case at redeem.
    it "leaves requested_role nil for a role-less human" do
      wire_user_idp(build_identity(actor: "human", agent_id: nil, user_id: user_id, role: nil))

      _status, html = dispatch(:link, method: "POST")

      expect(minted_row(html).requested_role).to be_nil
    end

    # THE REBIND HALF, end to end through the real `LinkCode.redeem` and the
    # real `AccountBinding.bind!` — the subtler consequence and the one no gate
    # covered. A nil `requested_role` omits the `allowed_roles` assignment from
    # the rebind UPDATE entirely, so the agent silently KEEPS its previous role
    # while its principal changes. Pinned on the SQL because that is where the
    # remap either happens or does not.
    it "rebinds a KNOWN key onto the new human's role via a browser-minted code" do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      wire_user_idp(build_identity(actor: "human", agent_id: nil, user_id: user_id, role: "owner"))
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:issue).and_return("kiosk-pop-jwt")

      _status, html = dispatch(:link, method: "POST")
      code = html[%r{<code>([^<]+)</code>}, 1]

      # The redeeming key is already registered under ANOTHER human, at
      # `customer` — the rebind case.
      rsa = OpenSSL::PKey::RSA.generate(2048)
      key_pem = rsa.public_key.to_pem
      route_exec_query(con) do |sql, _binds|
        if sql =~ /SELECT/i
          [{ "id" => "agent-known",
             "user_id" => "22222222-2222-2222-2222-222222222222",
             "allowed_roles" => "{customer}" }]
        else
          []
        end
      end
      challenge = Kiosk::Server::AuthChallenge.issue(public_key_pem: key_pem)
      proof = JWT.encode(
        { aud: "https://provider.example", nonce: challenge[:challenge], jti: SecureRandom.uuid },
        rsa, "RS256",
      )

      result = Kiosk::Server::LinkCode.redeem(
        code: code, public_key_pem: key_pem, signed: proof,
      )

      expect(result[:agent_id]).to eq("agent-known")   # same key, same agent
      expect(con.bound(/INSERT/i)).to be_empty         # ...so a rebind, not a fresh key
      sql, binds = con.bound(/UPDATE/i).first
      expect(sql).to include("allowed_roles = ARRAY[$3]::text[]")
      expect(binds).to eq([user_id, "agent-known", "owner"])
    end
  end

  it "unlinks via AccountBinding and reports it" do
    allow(Kiosk::Server::AccountBinding).to receive(:unlink!).and_return({ agent_id: "agent-1" })
    status, html = dispatch(:unlink, method: "POST", params: { "agent_id" => "agent-1" })

    expect(status).to eq(200)
    expect(html).to include("unlinked")
    expect(Kiosk::Server::AccountBinding).to have_received(:unlink!).with(
      agent_id: "agent-1", user_id: user_id,
    )
  end

  it "renders the envelope error inline when unlink misses" do
    allow(Kiosk::Server::AccountBinding).to receive(:unlink!)
      .and_raise(Kiosk::Server::Errors::NotFound.new("no linked assistant account with this agent_id"))
    status, html = dispatch(:unlink, method: "POST", params: { "agent_id" => "nope" })

    expect(status).to eq(404)
    expect(html).to include("no linked assistant account")
  end

  it "posts forms back to the page path regardless of mount (link/unlink suffix stripped)" do
    _status, html = dispatch(:link, method: "POST")
    expect(html).to include(%(action="/kiosk/auth/assistants/link"))
    expect(html).not_to include("/link/link")
  end

  it "surfaces the label, settled spend, and cap for each bound assistant (show)" do
    con.next_exec_result = [
      { "id" => "agent-1", "public_key" => pem, "created_at" => "2026-07-17 12:00:00+00",
        "human_label" => "Alice shopper", "spending_cap_cents" => 5000, "settled_cents" => 1200 },
    ]
    status, html = dispatch(:show, method: "GET")

    expect(status).to eq(200)
    expect(html).to include("Alice shopper")
    expect(html).to include("spent: 1200 cents")
    expect(html).to include("cap: 5000 cents")
    # The SELECT reaches for the new governance columns + the settled-spend subquery.
    select, binds = con.bound(/SELECT/i).first
    expect(select).to include("human_label")
    expect(select).to include("spending_cap_cents")
    expect(select).to include("settled_amount_cents")
    # No window configured → the statement declares ONE parameter and is sent
    # ONE argument. Postgres rejects a mismatch, which is why the statement and
    # its binds are built together (see #bound_assistants_query).
    expect(select).not_to include("$2")
    expect(binds).to eq([user_id])
  end

  # The rolling window is a VALUE, so it is `$2` through `make_interval` — the
  # same treatment executor.rb#settled_total_cents gives the same expression.
  it "binds the spending-cap window rather than splicing the day count" do
    Kiosk.configure { |c| c.spending_cap_window_days = 30 }
    con.next_exec_result = [
      { "id" => "agent-1", "public_key" => pem, "created_at" => "2026-07-17 12:00:00+00",
        "human_label" => nil, "spending_cap_cents" => nil, "settled_cents" => 0 },
    ]
    dispatch(:show, method: "GET")

    select, binds = con.bound(/SELECT/i).first
    expect(select).to include("make_interval(days => $2)")
    expect(select).not_to include("INTERVAL '1 day'")
    expect(binds).to eq([user_id, 30])
  end

  it "shows «(unnamed)» / «cap: none» when the label and cap are unset" do
    con.next_exec_result = [
      { "id" => "agent-1", "public_key" => pem, "created_at" => "2026-07-17 12:00:00+00",
        "human_label" => nil, "spending_cap_cents" => nil, "settled_cents" => 0 },
    ]
    _status, html = dispatch(:show, method: "GET")

    expect(html).to include("(unnamed)")
    expect(html).to include("cap: none")
  end

  it "shows «cap: disabled» when the cap is zero" do
    con.next_exec_result = [
      { "id" => "agent-1", "public_key" => pem, "created_at" => "2026-07-17 12:00:00+00",
        "human_label" => "Bot", "spending_cap_cents" => 0, "settled_cents" => 0 },
    ]
    _status, html = dispatch(:show, method: "GET")

    expect(html).to include("cap: disabled")
  end

  it "updates the label and spending cap, scoped by both agent id AND user_id" do
    status, html = dispatch(
      :update, method: "POST",
      params: { "agent_id" => "agent-1", "human_label" => "Alice's shopper", "spending_cap_cents" => "5000" },
    )

    expect(status).to eq(200)
    expect(html).to include("Assistant settings saved")
    upd, binds = con.bound(/UPDATE/i).first
    # WHICH columns are assigned is a statement shape the form decides; WHAT
    # they are assigned is a bind. `human_label` is free text off a form — the
    # most caller-reachable value in the auth plane — and the apostrophe in
    # "Alice's shopper" is exactly the character that used to need a `quote`.
    expect(upd).to include("human_label = $1")
    expect(upd).to include("spending_cap_cents = $2")
    # Ownership scoping: the WHERE pins BOTH the agent id and the session holder.
    expect(upd).to include("WHERE id = $3")
    expect(upd).to include("AND user_id = $4")
    expect(upd).to include("revoked_at IS NULL")
    expect(binds).to eq(["Alice's shopper", 5000, "agent-1", user_id])
    expect(con.all_sql).not_to include("Alice")
    expect(con).not_to have_received(:quote)
  end

  it "clears the cap (unlimited) when spending_cap_cents is blank" do
    _status, _html = dispatch(
      :update, method: "POST",
      params: { "agent_id" => "agent-1", "spending_cap_cents" => "" },
    )

    upd, binds = con.bound(/UPDATE/i).first
    # NULL is a statement shape (there is no value), so it takes no bind and the
    # ownership pair shifts down to $1/$2.
    expect(upd).to include("spending_cap_cents = NULL")
    expect(upd).to include("WHERE id = $1")
    expect(upd).to include("AND user_id = $2")
    expect(binds).to eq(["agent-1", user_id])
  end

  it "rejects a non-integer spending cap with 400 and writes no UPDATE" do
    status, html = dispatch(
      :update, method: "POST",
      params: { "agent_id" => "agent-1", "spending_cap_cents" => "lots" },
    )

    expect(status).to eq(400)
    expect(html).to include("must be an integer")
    expect(con.bound(/UPDATE/i)).to be_empty
  end

  # ── AGENT-SIGNPOST, the forgery-protection path (K-459) ───────────────────
  # A live assistant POSTing JSON at this `/kiosk/…` page carries no CSRF
  # token. Rails raises InvalidAuthenticityToken, and PRODUCTION answers it
  # with whatever the host's PublicExceptions has: the static public/422.html
  # every demo ships since K-532, a generic {"status":422,"error":…} echo on an
  # explicit JSON Accept, or a bodyless 422 (text/html, Content-Length 0) on a
  # host with no such page — never a pointer to the wire the caller wanted.
  #
  # A real Rails app installs `protect_from_forgery with: :exception` on every
  # ActionController::Base (config.action_controller.default_protect_from_forgery);
  # this bare Metal harness has no Rails app, so the subclass below opts in
  # explicitly to reproduce the production condition. Subclassing keeps the
  # shipped controller untouched for the rest of the suite.
  describe "forgery protection on a JSON POST" do
    let(:guarded) do
      stub_const(
        "ForgeryGuardedAssistantsController",
        Class.new(Kiosk::Server::AssistantsController) { protect_from_forgery with: :exception },
      )
    end

    def dispatch_guarded(env_overrides)
      env = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/auth/assistants/link", method: "POST",
      )
      env_overrides.each { |k, v| env[k] = v }
      env["rack.session"] = session
      status, headers, body = guarded.action(:link).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }
      [status, raw, headers]
    end

    it "answers a JSON-bodied POST with the error envelope and a pointer to the wire" do
      status, body, headers = dispatch_guarded(
        "CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new("{}"),
      )

      expect(status).to eq(422)
      expect(headers["Content-Type"]).to include("application/json")
      expect(body).not_to be_empty
      envelope = JSON.parse(body)
      expect(envelope["ok"]).to be(false)
      expect(envelope.dig("error", "code")).to eq("invalid_authenticity_token")
      expect(envelope.dig("error", "message")).to include("not the Kiosk wire")
      expect(envelope.dig("error", "hint"))
        .to include("https://provider.example/.well-known/kiosk.json")
    end

    it "answers an Accept: application/json POST the same way" do
      status, body, = dispatch_guarded("HTTP_ACCEPT" => "application/json")

      expect(status).to eq(422)
      expect(JSON.parse(body).dig("error", "code")).to eq("invalid_authenticity_token")
    end

    # The signpost must not soften the forgery gate for the surface it guards:
    # a browser form POST with a bad/absent token keeps failing exactly as it
    # does today (the exception propagates to Rails' own handling).
    it "still raises for a browser form POST — the CSRF gate is unchanged" do
      expect { dispatch_guarded("HTTP_ACCEPT" => "text/html") }
        .to raise_error(::ActionController::InvalidAuthenticityToken)
    end

    it "still raises for an ambiguous Accept: */* form POST" do
      expect { dispatch_guarded("HTTP_ACCEPT" => "*/*") }
        .to raise_error(::ActionController::InvalidAuthenticityToken)
    end
  end
end
