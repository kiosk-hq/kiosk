# frozen_string_literal: true

# Proof-of-possession itself is covered in pop_verifier_spec.rb; here it is
# stubbed so the login DB branch (known key → token, unknown key → 404) can be
# exercised in isolation with the FakeConnection.
RSpec.describe Kiosk::Server::AgentLogin do
  let(:pem) { "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----" }
  let(:con) { FakeConnection.new }

  before do
    allow(con).to receive(:quote).and_call_original
    Kiosk.configure do |c|
      c.roles  = %i[customer]
      c.schema = "kiosk"
    end
    ar_base = class_double("ActiveRecord::Base").as_stubbed_const
    allow(ar_base).to receive(:lease_connection).and_return(con)
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:issue).and_return("fresh-token")
    allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return({ nonce: "n" })
    allow(Kiosk::Server::AuthChallenge).to receive(:consume!).and_return(true)
  end

  it "mints a fresh token for a known key and provisions nothing" do
    route_exec_query(con) { [{ "id" => "agent-1", "user_id" => 42, "allowed_roles" => "{customer}" }] }

    result = described_class.call(public_key_pem: pem, signed: "sig")
    expect(result).to eq(access_token: "fresh-token")
    expect(con.all_sql).not_to match(/INSERT/i) # login never creates a row
  end

  # K-782: the presented key is the request body. It reaches the lookup as `$1`,
  # so it is never read as SQL — and the statement text cannot contain it.
  it "looks the key up through a bind parameter, never through the statement text" do
    route_exec_query(con) { [{ "id" => "agent-1", "user_id" => 42, "allowed_roles" => "{customer}" }] }
    hostile = "-----BEGIN PUBLIC KEY-----\n' OR '1'='1 --\n-----END PUBLIC KEY-----"

    described_class.call(public_key_pem: hostile, signed: "sig")

    sql, binds = con.bound(/SELECT/i).first
    expect(sql).to include("public_key = $1")
    expect(binds).to eq([hostile])
    expect(con.all_sql).not_to include("OR '1'='1")
    expect(con).not_to have_received(:quote)
  end

  it "proves possession and burns the challenge before the lookup" do
    route_exec_query(con) { [{ "id" => "a", "user_id" => 1, "allowed_roles" => "{customer}" }] }
    described_class.call(public_key_pem: pem, signed: "sig")
    expect(Kiosk::Server::PopVerifier).to have_received(:verify!)
    expect(Kiosk::Server::AuthChallenge).to have_received(:consume!).with(
      public_key_pem: pem, nonce: "n",
    )
  end

  it "raises NotFound for an unregistered key (no silent new account)" do
    route_exec_query(con) { [] }
    expect {
      described_class.call(public_key_pem: pem, signed: "sig")
    }.to raise_error(Kiosk::Server::Errors::NotFound, /no agent registered/)
  end

  # `allowed_roles` comes back as a Postgres text[] LITERAL string
  # ("{customer}") from the raw adapter, but some adapters/casts hand back a
  # real Ruby Array. primary_role must handle both — the String branch is
  # covered by the tests above; this pins the Array branch (allowed_roles.first).
  it "picks the first role from an Array-typed allowed_roles column" do
    route_exec_query(con) { [{ "id" => "agent-1", "user_id" => 42, "allowed_roles" => %w[staff customer] }] }
    idp_spy = instance_double(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp,
                              issue: "fresh-token")
    allow(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp).to receive(:new).and_return(idp_spy)

    described_class.call(public_key_pem: pem, signed: "sig")

    expect(idp_spy).to have_received(:issue).with(agent_id: "agent-1", role: "staff")
  end
end
