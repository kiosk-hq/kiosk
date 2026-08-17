# frozen_string_literal: true

RSpec.describe Kiosk::Server::AgentRegistration do
  let(:pem) { "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----" }

  before do
    Kiosk.reset!
    Kiosk.configure do |c|
      c.roles             = %i[customer]
      c.schema            = "kiosk"
      c.registration_role = :customer
    end
  end

  describe "role is pinned server-side (agents cannot choose it)" do
    it "does not accept a role argument on .call" do
      param_names = described_class.method(:call).parameters.map(&:last)
      expect(param_names).not_to include(:role)
    end

    it "does not accept a name argument on .call" do
      param_names = described_class.method(:call).parameters.map(&:last)
      expect(param_names).not_to include(:name)
    end

    it "raises ConfigurationError when registration_role is not among configured roles" do
      Kiosk.configure { |c| c.registration_role = :admin }
      expect {
        described_class.call(public_key_pem: "PEM", signed: "sig")
      }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /registration_role|roles/)
    end
  end

  # Proof-of-possession itself (signature, origin/`aud` binding, single-use
  # nonce) is covered in pop_verifier_spec.rb + auth_challenge_spec.rb. Here we
  # stub it so the DB-provisioning branch can be exercised in isolation.
  describe "provisioning (register-only; known keys 409, not re-issued)" do
    let(:con) { FakeConnection.new }

    before do
      ar_base = class_double("ActiveRecord::Base").as_stubbed_const
      allow(ar_base).to receive(:lease_connection).and_return(con)
      allow(con).to receive(:quote).and_call_original
      allow(Kiosk.configuration).to receive(:user_model).and_return(
        double(constantize: double(create!: double(id: 42)))
      )
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:issue).and_return("fake-token")
      # Isolate the DB branch: PoP proven, challenge burned.
      allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return({ nonce: "nonce-1" })
      allow(Kiosk::Server::AuthChallenge).to receive(:consume!).and_return(true)
    end

    it "requires a `signed` proof-of-possession argument" do
      param_names = described_class.method(:call).parameters
      expect(param_names).to include([:keyreq, :signed])
    end

    it "provisions a new agent and never writes a client-supplied name column" do
      results = [[], [{ "id" => "agent-1" }]] # SELECT empty → INSERT returns id
      route_exec_query(con) { |_sql, _binds| results.shift || [] }

      first = described_class.call(public_key_pem: pem, signed: "sig")
      expect(first[:user_id]).to eq("42")
      expect(first[:agent_id]).to eq("agent-1")

      insert_sql, binds = con.bound(/INSERT INTO kiosk\.agents/).first
      expect(insert_sql).not_to be_nil
      # `name` was removed from the wire + the row: the INSERT must not reference it.
      expect(insert_sql).not_to match(/\bname\b/)
      # K-782: the principal, the key and the role are `$1..$3` and NONE of them
      # is in the statement text — the register door is where a caller-supplied
      # key first reaches the database.
      expect(insert_sql).to include("VALUES ($1, ARRAY[$3]::text[], $2)")
      expect(binds).to eq([42, pem, "customer"])
      expect(con.all_sql).not_to include(pem)
      expect(con).not_to have_received(:quote)
    end

    it "burns the challenge and proves possession before touching the database" do
      route_exec_query(con) { |sql, _binds| sql =~ /INSERT/ ? [{ "id" => "a" }] : [] }
      described_class.call(public_key_pem: pem, signed: "sig")
      expect(Kiosk::Server::PopVerifier).to have_received(:verify!)
      expect(Kiosk::Server::AuthChallenge).to have_received(:consume!).with(
        public_key_pem: pem, nonce: "nonce-1",
      )
    end

    it "raises Conflict on an already-registered public key (use /auth/login)" do
      # SELECT returns an existing agent row → register must refuse, not re-issue.
      route_exec_query(con) { [{ "id" => "agent-1" }] }
      expect {
        described_class.call(public_key_pem: pem, signed: "sig")
      }.to raise_error(Kiosk::Server::Errors::Conflict, /already registered/)
    end

    # Roles are hook-or-absent in 0.1. registration_role is OPTIONAL — when
    # unset, the code writes NO role.
    #
    # WHAT THIS EXAMPLE DOES NOT PROVE, and the reason it is named here rather
    # than left implied: the SHIPPED migration declares `allowed_roles text[]
    # NOT NULL`, so this branch cannot reach a real database at all — a provider
    # with no `registration_role` gets a NOT NULL violation on every register.
    # A fake accepts any statement, which is exactly how that survived. Filed as
    # K-788 and characterised against a real Postgres in
    # auth_plane_persistence_spec.rb.
    it "writes NULL allowed_roles with registration_role unset (see K-788)" do
      Kiosk.configure { |c| c.registration_role = nil }
      results = [[], [{ "id" => "agent-1" }]] # SELECT empty → INSERT returns id
      route_exec_query(con) { |_sql, _binds| results.shift || [] }

      result = described_class.call(public_key_pem: pem, signed: "sig")
      expect(result[:agent_id]).to eq("agent-1")
      expect(result[:access_token]).to eq("fake-token")

      insert_sql, binds = con.bound(/INSERT INTO kiosk\.agents/).first
      expect(insert_sql).to include("NULL")
      expect(insert_sql).not_to match(/ARRAY\[/)
      expect(binds).to eq([42, pem]) # no third bind: NULL is a shape, not a value
    end

    it "treats an empty-string registration_role as unset (no ConfigurationError)" do
      Kiosk.configure { |c| c.registration_role = "" }
      results = [[], [{ "id" => "agent-1" }]]
      route_exec_query(con) { |_sql, _binds| results.shift || [] }

      expect(described_class.call(public_key_pem: pem, signed: "sig")[:agent_id])
        .to eq("agent-1")
    end
  end

  # ─── assistant-account factory ───────────────────────────────
  # When the provider configures `assistant_creation`, the framework invokes it
  # with ONE arg (the pubkey) and USES the return value as the principal
  # (`agents.user_id`). The provider persists its OWN record and returns that
  # record's id — so a bigint (or any non-uuid) id flows straight through,
  # instead of the framework forcing a uuid principal that 500s on bigint apps.
  describe "assistant-account factory (config.assistant_creation)" do
    let(:con) { FakeConnection.new }

    before do
      ar_base = class_double("ActiveRecord::Base").as_stubbed_const
      allow(ar_base).to receive(:lease_connection).and_return(con)
      allow(con).to receive(:quote).and_call_original
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:issue).and_return("fake-token")
      allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return({ nonce: "nonce-1" })
      allow(Kiosk::Server::AuthChallenge).to receive(:consume!).and_return(true)
      # SELECT (dup check) empty → INSERT returns the agent id.
      results = [[], [{ "id" => "agent-1" }]]
      route_exec_query(con) { |_sql, _binds| results.shift || [] }
    end

    it "calls the factory with ONLY the pubkey and uses its RETURN as the principal" do
      captured = {}
      Kiosk.configure do |c|
        c.assistant_creation = ->(pubkey) do
          captured[:args] = pubkey
          # A provider on bigint PKs returns an INTEGER id — this must flow through
          # untouched (the old contract forced a uuid principal and 500'd here).
          987_654
        end
      end

      result = described_class.call(public_key_pem: pem, signed: "sig")

      # Block received exactly one positional arg: the pubkey (no framework-minted id).
      expect(described_class.method(:create_assistant_account)).not_to be_nil
      expect(captured[:args]).to eq(pem)
      # …and the block's return value IS the agent's principal in the response.
      expect(result[:user_id]).to eq("987654")
    end

    it "flows a bigint principal id straight through to agents.user_id (no uuid coercion)" do
      results = [[], [{ "id" => "agent-1" }]]
      route_exec_query(con) { |_sql, _binds| results.shift || [] }
      Kiosk.configure { |c| c.assistant_creation = ->(_pubkey) { 42 } }

      described_class.call(public_key_pem: pem, signed: "sig")

      _insert_sql, binds = con.bound(/INSERT INTO kiosk\.agents/).first
      # The integer id — NOT a uuid, and NOT stringified on the way in — is what
      # lands in the row. It reaches Postgres as a bind, so the COLUMN's type
      # decides how it is read, which is what lets one engine serve bigint and
      # uuid principals alike.
      expect(binds.first).to eq(42)
      expect(con.all_sql).not_to match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/)
    end

    it "raises ConfigurationError when the factory returns nil (must return an id)" do
      Kiosk.configure { |c| c.assistant_creation = ->(_pubkey) { nil } }
      expect {
        described_class.call(public_key_pem: pem, signed: "sig")
      }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /assistant_creation returned nil/)
    end

    it "does NOT fall back to user_model.create! when the factory is set" do
      user_model = double("UserModel")
      allow(user_model).to receive(:create!).and_return(double(id: 999))
      allow(Kiosk.configuration).to receive(:user_model)
        .and_return(double(constantize: user_model))
      Kiosk.configure { |c| c.assistant_creation = ->(_pubkey) { 7 } }

      described_class.call(public_key_pem: pem, signed: "sig")

      expect(user_model).not_to have_received(:create!)
    end
  end
end
