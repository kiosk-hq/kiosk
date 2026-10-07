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

  # Spec Section 8.5.6: re-authorised at least every 60 seconds, both the
  # credential (here) and each subscription's reach (the channel's timer).
  it "ships re-authorisation periods of at most 60 seconds" do
    periods = KioskEvents.periodic_timers.map { |_callback, options| options[:every] }
    expect(periods + [described_class.reauthorise_every]).to all(be_between(1, 60))
  end
end
