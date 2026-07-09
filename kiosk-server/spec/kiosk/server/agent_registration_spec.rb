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
  # When the provider configures `assistant_creation`, the framework generates
  # the assistant-account id and hands it (with the pubkey) to the provider,
  # which persists its OWN record. The generated id becomes the principal —
  # NOT a bare `user_model.create!` (which 500s on any validated model).
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

    it "calls the factory with (assistant_account_id, pubkey) and uses that id as the principal" do
      captured = {}
      Kiosk.configure do |c|
        c.assistant_creation = ->(assistant_account_id, pubkey) do
          captured[:id]     = assistant_account_id
          captured[:pubkey] = pubkey
        end
      end

      result = described_class.call(public_key_pem: pem, signed: "sig")

      # The framework generated a UUID and passed it to the provider…
      expect(captured[:id]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      expect(captured[:pubkey]).to eq(pem)
      # …and that same id is the agent's principal in the response.
      expect(result[:user_id]).to eq(captured[:id])
    end

    it "does NOT fall back to user_model.create! when the factory is set" do
      user_model = double("UserModel")
      allow(user_model).to receive(:create!).and_return(double(id: 999))
      allow(Kiosk.configuration).to receive(:user_model)
        .and_return(double(constantize: user_model))
      Kiosk.configure { |c| c.assistant_creation = ->(_id, _pubkey) {} }

      described_class.call(public_key_pem: pem, signed: "sig")

      expect(user_model).not_to have_received(:create!)
    end

    it "writes the generated principal id into the agents row" do
      captured_id = nil
      executed    = []
      results     = [[], [{ "id" => "agent-1" }]]
      allow(con).to receive(:execute) { |sql| executed << sql; results.shift || [] }
      Kiosk.configure do |c|
        c.assistant_creation = ->(assistant_account_id, _pubkey) { captured_id = assistant_account_id }
      end

      described_class.call(public_key_pem: pem, signed: "sig")

      insert_sql = executed.find { |s| s =~ /INSERT INTO kiosk\.agents/ }
      expect(insert_sql).to include(captured_id)
    end
  end
end
