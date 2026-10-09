# frozen_string_literal: true

require "kiosk/owned"

RSpec.describe Kiosk::Owned do
  let(:model) do
    Class.new do
      def self.scope(name, body) = define_singleton_method(name, &body)
      def self.where(**conditions) = conditions
      include Kiosk::Owned
    end
  end
  let(:identity) { Kiosk::Identity.new(user_id: "u-1", role: "customer", actor: "agent", agent_id: "a-1") }

  it "scopes to the principal of the open session" do
    rows = Kiosk::Server::SessionContext.open(connection: FakeConnection.new, identity:) { model.own }
    expect(rows).to eq(user_id: "u-1")
  end

  it "refuses outside a session instead of answering an empty relation" do
    expect { model.own }.to raise_error(Kiosk::Server::Errors::Unauthenticated)
    expect { Kiosk.current_role }.to raise_error(Kiosk::Server::Errors::Unauthenticated)
  end
end
