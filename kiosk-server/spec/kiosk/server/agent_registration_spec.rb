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

    it "raises ConfigurationError when registration_role is unset (loud misconfiguration)" do
      Kiosk.configure { |c| c.registration_role = nil }
      expect {
        described_class.call(public_key_pem: "PEM", signed: "sig")
      }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /registration_role/)
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
      allow(ar_base).to receive(:connection).and_return(con)
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
      results  = [[], [{ "id" => "agent-1" }]] # SELECT empty → INSERT returns id
      executed = []
      allow(con).to receive(:execute) { |sql| executed << sql; results.shift || [] }

      first = described_class.call(public_key_pem: pem, signed: "sig")
      expect(first[:user_id]).to eq("42")
      expect(first[:agent_id]).to eq("agent-1")

      insert_sql = executed.find { |s| s =~ /INSERT INTO kiosk\.agents/ }
      expect(insert_sql).not_to be_nil
      # `name` was removed from the wire + the row: the INSERT must not reference it.
      expect(insert_sql).not_to match(/\bname\b/)
      # The role written is the server-pinned config role.
      expect(insert_sql).to match(/ARRAY\['customer'\]/)
    end

    it "burns the challenge and proves possession before touching the database" do
      allow(con).to receive(:execute) { |sql| sql =~ /INSERT/ ? [{ "id" => "a" }] : [] }
      described_class.call(public_key_pem: pem, signed: "sig")
      expect(Kiosk::Server::PopVerifier).to have_received(:verify!)
      expect(Kiosk::Server::AuthChallenge).to have_received(:consume!).with(
        public_key_pem: pem, nonce: "nonce-1",
      )
    end

    it "raises Conflict on an already-registered public key (use /auth/login)" do
      # SELECT returns an existing agent row → register must refuse, not re-issue.
      allow(con).to receive(:execute).and_return([{ "id" => "agent-1" }])
      expect {
        described_class.call(public_key_pem: pem, signed: "sig")
      }.to raise_error(Kiosk::Server::Errors::Conflict, /already registered/)
    end
  end

  # ─── assistant-account factory (ADR-0010) ───────────────────────────────
  # When the provider configures `assistant_creation`, the framework invokes it
  # with ONE arg (the pubkey) and USES the return value as the principal
  # (`agents.user_id`). The provider persists its OWN record and returns that
  # record's id — so a bigint (or any non-uuid) id flows straight through,
  # instead of the framework forcing a uuid principal that 500s on bigint apps.
  describe "assistant-account factory (config.assistant_creation)" do
    let(:con) { FakeConnection.new }

    before do
      ar_base = class_double("ActiveRecord::Base").as_stubbed_const
      allow(ar_base).to receive(:connection).and_return(con)
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:issue).and_return("fake-token")
      allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return({ nonce: "nonce-1" })
      allow(Kiosk::Server::AuthChallenge).to receive(:consume!).and_return(true)
      # SELECT (dup check) empty → INSERT returns the agent id.
      results = [[], [{ "id" => "agent-1" }]]
      allow(con).to receive(:execute) { |_sql| results.shift || [] }
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
      executed = []
      results  = [[], [{ "id" => "agent-1" }]]
      allow(con).to receive(:execute) { |sql| executed << sql; results.shift || [] }
      Kiosk.configure { |c| c.assistant_creation = ->(_pubkey) { 42 } }

      described_class.call(public_key_pem: pem, signed: "sig")

      insert_sql = executed.find { |s| s =~ /INSERT INTO kiosk\.agents/ }
      # The integer id — NOT a uuid — is what lands in the row.
      expect(insert_sql).to match(/VALUES \('42'/)
      expect(insert_sql).not_to match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/)
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
