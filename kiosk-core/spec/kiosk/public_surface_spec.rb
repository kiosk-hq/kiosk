# frozen_string_literal: true

# Pins the removal of dead seams: these constants
# had no subclass, no config attribute, and no caller anywhere in the
# reference tree. Reintroduce only alongside a shipped transport/broker
# implementation and an ADR.
RSpec.describe "Kiosk public surface" do
  it "does not define the removed CredentialBrokers seam" do
    expect(Kiosk.const_defined?(:CredentialBrokers)).to be(false)
  end

  it "does not define the removed NotificationAdapter seam" do
    expect(Kiosk.const_defined?(:NotificationAdapter)).to be(false)
  end

  it "does not define the removed Event value type" do
    expect(Kiosk.const_defined?(:Event)).to be(false)
  end
end
