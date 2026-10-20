# frozen_string_literal: true

require 'logger'
require 'stringio'

RSpec.describe Kiosk::Server::EventsConnection do
  it 'logs a re-authorisation that raises rather than losing it to the worker pool' do
    log = StringIO.new
    connection = described_class.allocate
    allow(connection).to receive(:logger).and_return(Logger.new(log))
    allow(connection).to receive(:kiosk_credential_holds?)
      .and_raise(NoMethodError, "private method 'request' called")

    expect { connection.send(:reauthorise!) }.not_to raise_error
    expect(log.string).to include(
      "[kiosk] events re-authorisation failed: NoMethodError: private method 'request' called"
    )
  end

  # Spec Section 8.5.6: re-authorised at least every 60 seconds, both the
  # credential (here) and each subscription's reach (the channel's timer).
  it 'ships re-authorisation periods of at most 60 seconds' do
    periods = KioskEvents.periodic_timers.map { |_callback, options| options[:every] }
    expect(periods + [described_class.reauthorise_every]).to all(be_between(1, 60))
  end

  describe 'identity' do
    # A page on a sibling subdomain is same-site, so its socket carries the
    # human's cookie; the upgrade must not turn that cookie into an identity.
    it 'resolves no identity from a signed-in session cookie' do
      human = build_identity(actor: 'human', agent_id: nil)
      Kiosk.configure do |c|
        c.issuer   = 'https://demo.example'
        c.user_idp = Class.new { define_method(:verify) { |_r| human } }.new
      end
      connection = described_class.allocate
      env = Rack::MockRequest.env_for('https://demo.example/kiosk/events', 'HTTP_COOKIE' => '_session=signed-in')
      allow(connection).to receive(:request).and_return(ActionDispatch::Request.new(env))

      expect(connection.send(:resolve_identity)).to be_nil
    end
  end
end
