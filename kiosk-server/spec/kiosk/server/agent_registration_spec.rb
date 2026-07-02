# frozen_string_literal: true

RSpec.describe Kiosk::Server::AgentRegistration do
  before do
    Kiosk.reset!
    Kiosk.configure { |c| c.roles = %i[customer]; c.schema = "kiosk" }
  end

  it "rejects a role not in Kiosk.configuration.roles (before any DB access)" do
    expect {
      described_class.call(name: "X", public_key_pem: "PEM", role: "admin")
    }.to raise_error(Kiosk::Server::Errors::BadRequest, /role/)
  end

  describe "idempotency" do
    let(:con) { FakeConnection.new }
    let(:pem) { "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----" }

    before do
      ar_base = class_double("ActiveRecord::Base").as_stubbed_const
      allow(ar_base).to receive(:connection).and_return(con)
      allow(Kiosk.configuration).to receive(:user_model).and_return(
        double(constantize: double(create!: double(id: 42)))
      )
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:issue).and_return("fake-token")
    end

    it "returns the same user_id on repeated registration with the same public key" do
      results = [[], [{ "id" => "agent-1" }]]  # SELECT empty → INSERT
      allow(con).to receive(:execute) { |sql| con.instance_variable_get(:@executed_sql) << sql; results.shift || [] }

      first = described_class.call(name: "test", public_key_pem: pem, role: "customer")
      expect(first[:user_id]).to eq("42")
      expect(first[:agent_id]).to eq("agent-1")

      # Second call: agent exists → returns same user_id without creating new user
      con.instance_variable_get(:@executed_sql).clear
      allow(con).to receive(:execute).and_return([{ "id" => "agent-1", "user_id" => 42, "allowed_roles" => "{customer}" }])
      second = described_class.call(name: "test", public_key_pem: pem, role: "customer")
      expect(second[:user_id]).to eq("42")
      expect(second[:agent_id]).to eq("agent-1")
    end
  end
end
