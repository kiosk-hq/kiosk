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
end
