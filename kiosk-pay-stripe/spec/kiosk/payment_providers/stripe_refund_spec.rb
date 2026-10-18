# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe, '#refund' do
  include_context 'with a Stripe adapter'

  it 'reverses the named PaymentIntent for the amount, keyed by the charge it undoes' do
    refund = double('Refund', id: 're_123', amount: 1599, created: 1_700_000_100)
    expect(stripe.refunds).to receive(:create).with(
      { payment_intent: 'pi_123', amount: 1599 },
      { idempotency_key: 'pi_123-refund' }
    ).and_return(refund)

    expect(adapter.refund(psp_reference: 'pi_123', amount_cents: 1599)).to eq(
      psp_reference: 're_123',
      refunded_psp_reference: 'pi_123',
      refunded_amount_cents: 1599,
      refunded_at: Time.at(1_700_000_100).utc
    )
  end

  it "answers PaymentFailed when Stripe cannot refund, without Stripe's text" do
    allow(stripe.refunds).to receive(:create)
      .and_raise(Stripe::InvalidRequestError.new('Charge ch_1 has already been refunded.', nil))

    expect { adapter.refund(psp_reference: 'pi_123', amount_cents: 1599) }
      .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
        expect(e.reason).to eq(:refund_failed)
        expect(e.message).not_to match(/ch_1/)
      }
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#refund against stripe-mock' do
  include_context 'with a Stripe adapter'

  it 'refunds a charge against stripe-mock' do
    with_stripe_mock do |mocked|
      receipt = mocked.refund(psp_reference: 'pi_123', amount_cents: 1599)
      expect(receipt[:psp_reference]).to start_with('re_')
      expect(receipt[:refunded_psp_reference]).to eq('pi_123')
    end
  end
end
