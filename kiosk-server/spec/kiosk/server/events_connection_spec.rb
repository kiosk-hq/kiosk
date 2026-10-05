# frozen_string_literal: true

require "logger"
require "stringio"

# What the re-authorisation timer does when the call it makes RAISES: Action
# Cable's worker pool would swallow it into a logger the engine does not own.
RSpec.describe Kiosk::Server::EventsConnection do
  it "logs a re-authorisation that raises rather than losing it to the worker pool" do
    log = StringIO.new
    connection = described_class.allocate
    allow(connection).to receive(:logger).and_return(Logger.new(log))
    allow(connection).to receive(:kiosk_credential_holds?)
      .and_raise(NoMethodError, "private method 'request' called")

    expect { connection.send(:reauthorise!) }.not_to raise_error
    expect(log.string).to include(
      "[kiosk] events re-authorisation failed: NoMethodError: private method 'request' called",
    )
  end
end
