# frozen_string_literal: true

require 'kiosk/test_helpers/mandate'

# One signing key for the suite: generating a 2048-bit key per example is slow.
CHECKOUT_SIGNING_KEY = Kiosk::Server::SigningKey.generate

# An origin that signs checkouts, an agent whose registered key signs the two
# closed AP2 mandates, and a checkout of 450 cents for order `o-1`.
RSpec.shared_context 'with a checkout to pay' do
  let(:agent_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:identity)  { build_identity(agent_id: 'agent-1', user_id: 'u-1') }
  let(:checkout_jwt) { checkout(total_amount_cents: 450) }
  let(:mandates) { Kiosk::TestHelpers::Mandate.pay(agent_key, checkout_jwt) }

  before do
    Kiosk.configure do |c|
      c.issuer      = issuer
      c.signing_key = CHECKOUT_SIGNING_KEY
      c.owner       = { name: 'Demo' }
    end
    agent_idp = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
    allow(agent_idp).to receive(:agent_payment_key).with('agent-1').and_return(agent_key.public_key)
    allow(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp).to receive(:new).and_return(agent_idp)
  end

  def issuer = 'https://demo.example'

  def line_items = [{ 'order_id' => 'o-1' }, { 'qty' => 1, 'price_cents' => 450 }]

  # A checkout this origin signs for `user_id`.
  def checkout(user_id: 'u-1', currency: 'eur', total_amount_cents: 450, line_items: self.line_items)
    Kiosk::Server::Checkout.sign(user_id:, currency:, total_amount_cents:, line_items:)
  end

  # `sd_jwt` with its mandate changed and signed again by `key`.
  def resign(sd_jwt, key: agent_key, **changes)
    content = Kiosk::TestHelpers::Mandate.content(sd_jwt).merge(changes.transform_keys(&:to_s))
    Kiosk::TestHelpers::Mandate.sign(key, content.compact)
  end
end
