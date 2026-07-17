# frozen_string_literal: true

# The «Link an assistant» engine page (ADR-0017): session-authed listing of
# bound assistant accounts + mint/unlink, HTML shim over LinkCode /
# AccountBinding. Same Metal-dispatch harness as the other controller specs.

require "action_controller"
require "rack/mock"
require "openssl"

load File.expand_path("../../../lib/kiosk/server/assistants_controller.rb", __dir__)

RSpec.describe "AssistantsController" do
  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }
  let(:human)   { build_identity(actor: "human", agent_id: nil, user_id: user_id) }
  let(:pem)     { OpenSSL::PKey::RSA.generate(2048).public_key.to_pem }
  let(:con)     { FakeConnection.new }
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
    allow(ar_base).to receive(:connection).and_return(con)
  end

  def dispatch(action, method:, params: {})
    path = action == :show ? "" : "/#{action}"
    env = Rack::MockRequest.env_for(
      "https://provider.example/kiosk/auth/assistants#{path}",
      method: method, params: params,
    )
    env["rack.session"] = session
    status, _headers, body = Kiosk::Server::AssistantsController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, raw]
  end

  it "401s without a provider session" do
    wire_user_idp(nil)
    status, body = dispatch(:show, method: "GET")
    expect(status).to eq(401)
    expect(body).to include("Sign in")
  end

  it "lists the holder's bound assistant accounts with key fingerprints" do
    con.next_result = [
      { "id" => "agent-1", "public_key" => pem, "created_at" => "2026-07-17 12:00:00+00" },
    ]
    status, html = dispatch(:show, method: "GET")

    expect(status).to eq(200)
    expect(html).to include("Linked assistant accounts")
    expect(html).to include(Kiosk::Server::SigningKey.from_pem(pem).kid)
    expect(html).to include(%(value="agent-1"))
    # The SELECT is scoped to the session holder's live rows.
    select = con.executed_sql.grep(/SELECT/i).first
    expect(select).to include("user_id = '#{user_id}'")
    expect(select).to include("revoked_at IS NULL")
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
end
