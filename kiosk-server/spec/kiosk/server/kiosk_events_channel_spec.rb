# frozen_string_literal: true

require "logger"
require "stringio"

# The one property the real-socket driver cannot reach: what the
# re-authorisation timer does when the call it makes RAISES.
#
# Action Cable's worker pool catches everything a periodic callback throws and
# writes it to `ActionCable.server.logger` — the HOST application's singleton,
# which the engine neither owns nor configures. So a failure of this timer is
# invisible to the operator unless the engine says it in its own log.
RSpec.describe KioskEvents do
  it "logs a re-authorisation that raises rather than losing it to the worker pool" do
    log = StringIO.new
    connection = double("connection", identifiers: [], logger: Logger.new(log))
    allow(connection).to receive(:kiosk_identity_resolves?)
      .and_raise(NoMethodError, "private method 'request' called")

    channel = described_class.new(connection, "ident")
    channel.instance_variable_set(:@declaration, { reach: :principal })

    expect { channel.send(:reauthorise!) }.not_to raise_error
    expect(log.string).to include(
      "[kiosk] events re-authorisation failed: NoMethodError: private method 'request' called",
    )
  end
end
