# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture' do
  include_context 'with a Stripe adapter'

  let(:pi) do
    double('PaymentIntent', id: 'pi_123', status: 'succeeded', amount: 1599, amount_received: 1599,
                            created: 1_700_000_000)
  end

  it "charges the customer's default saved card off_session, keyed by the cart mandate id" do
    stub_customer(default_pm: 'pm_default_visa')
    expect(Stripe::PaymentIntent).to receive(:create).with(
      {
        amount: 1599,
        currency: 'eur',
        customer: 'cus_existing',
        payment_method: 'pm_default_visa',
        payment_method_types: ['card'],
        off_session: true,
        confirm: true,
        metadata: { cart_mandate_id: 'cart-1' }
      },
      { idempotency_key: 'cart-1-capture' }
    ).and_return(pi)

    result = adapter.capture(cart_mandate, payment_method: nil)
    expect(result[:psp_reference]).to eq('pi_123')
    expect(result[:settled_amount_cents]).to eq(1599)
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture with no default card' do
  include_context 'with a Stripe adapter'

  it 'falls back to the first listed card when no default PM is set' do
    stub_customer(listed: ['pm_listed_visa'])

    expect(Stripe::PaymentIntent).to receive(:create).with(
      hash_including(customer: 'cus_existing', payment_method: 'pm_listed_visa'),
      anything
    ).and_return(double('PaymentIntent', id: 'pi_123', status: 'succeeded', amount_received: 1599, created: 0))

    adapter.capture(cart_mandate, payment_method: nil)
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture without a saved card' do
  include_context 'with a Stripe adapter'

  it 'raises SetupRequired when the customer has no saved card' do
    stub_customer(listed: [])

    expect do
      adapter.capture(cart_mandate, payment_method: nil)
    end.to raise_error(Kiosk::PaymentProviders::SetupRequired)
  end

  it 'raises SetupRequired when the resolver returns nil (unknown user)' do
    expect do
      no_customer_adapter.capture(cart_mandate, payment_method: nil)
    end.to raise_error(Kiosk::PaymentProviders::SetupRequired)
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture of the saved card' do
  include_context 'with a Stripe adapter'

  before { stub_customer(default_pm: 'pm_default_visa') }

  it 'ignores an explicitly presented pm and charges the on-file card when a resolver is configured' do
    # The assistant authorizes and never presents a card, so a presented pm is
    # ignored and the saved card is charged.
    expect(Stripe::PaymentIntent).to receive(:create).with(
      hash_including(customer: 'cus_existing', payment_method: 'pm_default_visa'),
      anything
    ).and_return(double('PaymentIntent', id: 'pi_123', status: 'succeeded', amount_received: 1599, created: 0))

    adapter.capture(cart_mandate, payment_method: 'pm_explicit')
  end

  it 'settles what the intent received, not what it asked for' do
    allow(Stripe::PaymentIntent).to receive(:create)
      .and_return(double('PaymentIntent', id: 'pi_part', status: 'succeeded', amount: 1599,
                                          amount_received: 1500, created: 0))

    expect(adapter.capture(cart_mandate)[:settled_amount_cents]).to eq(1500)
  end

  # stripe-mock answers every confirmed intent `requires_payment_method` with
  # `amount_received: 0`: Stripe's shape for a declined off_session confirm.
  it "refuses stripe-mock's unpaid intent as a retryable decline" do
    with_stripe_mock do
      allow(Stripe::Customer).to receive(:retrieve).and_call_original
      expect { adapter.capture(cart_mandate) }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e).to be_retryable
          expect(e.reason).to eq(:card_declined)
        }
    end
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture when the intent did not succeed' do
  include_context 'with a Stripe adapter'

  before { stub_customer(default_pm: 'pm_default_visa') }

  def intent(status)
    double('PaymentIntent', id: "pi_#{status}", status: status, amount: 1599, amount_received: 0, created: 0)
  end

  %w[requires_payment_method canceled].each do |status|
    it "treats #{status} as a retryable decline: nothing was collected" do
      allow(Stripe::PaymentIntent).to receive(:create).and_return(intent(status))

      expect { adapter.capture(cart_mandate) }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e).to be_retryable
          expect(e.reason).to eq(:card_declined)
        }
    end
  end

  %w[processing requires_action requires_confirmation requires_capture].each do |status|
    it "treats #{status} as an unknown outcome that must not be retried" do
      allow(Stripe::PaymentIntent).to receive(:create).and_return(intent(status))

      expect { adapter.capture(cart_mandate) }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e).not_to be_retryable
          expect(e.reason).to eq(:processor_unavailable)
        }
    end
  end
end

# A charge failure surfaces as a PSP-agnostic PaymentFailed with a human-safe
# message, so the executor renders a typed `payment_failed` 402.
RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture when the charge fails at Stripe' do
  include_context 'with a Stripe adapter'

  before { stub_customer(default_pm: 'pm_default_visa') }

  it 'translates a Stripe::CardError (declined) into a RETRYABLE PaymentFailed with a safe message' do
    allow(Stripe::PaymentIntent).to receive(:create)
      .and_raise(Stripe::CardError.new('Your card was declined.', nil, code: 'card_declined'))

    expect { adapter.capture(cart_mandate) }
      .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
        expect(e).to be_retryable
        expect(e.reason).to eq(:card_declined)
        expect(e.message).to eq('the payment method was declined')
        # No raw Stripe text leaks through.
        expect(e.message).not_to match(/Your card was declined/)
      }
  end

  it 'maps authentication_required to a distinct human-safe message (still retryable)' do
    allow(Stripe::PaymentIntent).to receive(:create)
      .and_raise(Stripe::CardError.new('auth', nil, code: 'authentication_required'))

    expect { adapter.capture(cart_mandate) }
      .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
        expect(e).to be_retryable
        expect(e.message).to match(/authentication/i)
      }
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture when Stripe cannot confirm the charge' do
  include_context 'with a Stripe adapter'

  before { stub_customer(default_pm: 'pm_default_visa') }

  it 'translates a non-card Stripe error (timeout/connectivity) into a NON-retryable PaymentFailed (unknown outcome)' do
    allow(Stripe::PaymentIntent).to receive(:create)
      .and_raise(Stripe::APIConnectionError.new('timed out'))

    expect { adapter.capture(cart_mandate) }
      .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
        expect(e).not_to be_retryable
        expect(e.reason).to eq(:processor_unavailable)
        expect(e.message).to match(/unknown/i)
        expect(e.message).not_to match(/timed out/)
      }
  end
end
