# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe do
  describe '#capture' do
    include_context 'with a Stripe adapter'

    let(:pi) do
      Stripe::PaymentIntent.construct_from(id: 'pi_123', status: 'succeeded', amount: 1599, amount_received: 1599,
                                           created: 1_700_000_000, latest_charge: charge('583910485721044'))
    end

    it "charges the customer's saved card off_session, keyed by the Stripe customer and the checkout mandate reference" do
      stub_cards('pm_default_visa')
      allow(stripe.payment_intents).to receive(:create).and_return(pi)

      result = adapter.capture(checkout_mandate, payment_method: nil)

      expect(stripe.payment_intents).to have_received(:create).with(
        {
          amount: 1599,
          currency: 'eur',
          customer: 'cus_existing',
          payment_method: 'pm_default_visa',
          payment_method_types: ['card'],
          off_session: true,
          confirm: true,
          metadata: { checkout_mandate: 'checkout-1' },
          expand: ['latest_charge']
        },
        { idempotency_key: 'cus_existing-checkout-1-capture' }
      )
      expect(result[:psp_reference]).to eq('pi_123')
      expect(result[:settled_amount_cents]).to eq(1599)
      expect(result[:network_confirmation_id]).to eq('583910485721044')
    end

    it 'reports no network id when the card network returned none' do
      stub_cards('pm_default_visa')
      allow(stripe.payment_intents).to receive(:create)
        .and_return(Stripe::PaymentIntent.construct_from(id: 'pi_123', status: 'succeeded', amount_received: 1599,
                                                         created: 0, latest_charge: charge(nil)))

      expect(adapter.capture(checkout_mandate)[:network_confirmation_id]).to be_nil
    end

    it 'captures against stripe-mock, which reports no network id' do
      with_stripe_mock do |mocked|
        captured = mocked.capture(checkout_mandate)

        expect(captured).to include(psp_reference: start_with('pi_'), network_confirmation_id: nil)
      end
    end
  end

  describe '#capture, counted in Stripe calls' do
    include_context 'with a Stripe adapter'

    it 'lists the cards once and creates the intent, and reads no Customer' do
      stub_cards('pm_listed_visa')
      allow(stripe.payment_intents).to receive(:create)
        .and_return(Stripe::PaymentIntent.construct_from(id: 'pi_123', status: 'succeeded', amount_received: 1599,
                                                         created: 0, latest_charge: charge(nil)))

      adapter.capture(checkout_mandate)

      expect(stripe.payment_methods).to have_received(:list).once
      expect(stripe.customers).not_to have_received(:retrieve)
    end
  end

  describe '#capture without a saved card' do
    include_context 'with a Stripe adapter'

    it 'raises SetupRequired when the customer has no saved card' do
      stub_cards

      expect do
        adapter.capture(checkout_mandate, payment_method: nil)
      end.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    end

    it 'raises SetupRequired when the resolver returns nil (unknown user)' do
      expect do
        no_customer_adapter.capture(checkout_mandate, payment_method: nil)
      end.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    end
  end

  describe '#capture of the saved card' do
    include_context 'with a Stripe adapter'

    before { stub_cards('pm_default_visa') }

    it 'ignores an explicitly presented pm and charges the on-file card when a resolver is configured' do
      # The assistant authorizes and never presents a card, so a presented pm is
      # ignored and the saved card is charged.
      allow(stripe.payment_intents).to receive(:create)
        .and_return(Stripe::PaymentIntent.construct_from(id: 'pi_123', status: 'succeeded', amount_received: 1599,
                                                         created: 0, latest_charge: charge(nil)))

      adapter.capture(checkout_mandate, payment_method: 'pm_explicit')

      expect(stripe.payment_intents).to have_received(:create).with(
        hash_including(customer: 'cus_existing', payment_method: 'pm_default_visa'),
        anything
      )
    end

    it 'settles what the intent received, not what it asked for' do
      allow(stripe.payment_intents).to receive(:create)
        .and_return(Stripe::PaymentIntent.construct_from(id: 'pi_part', status: 'succeeded', amount: 1599,
                                                         amount_received: 1500, created: 0,
                                                         latest_charge: charge(nil)))

      expect(adapter.capture(checkout_mandate)[:settled_amount_cents]).to eq(1500)
    end
  end

  describe '#capture when the intent did not succeed' do
    include_context 'with a Stripe adapter'

    before { stub_cards('pm_default_visa') }

    def intent(status)
      Stripe::PaymentIntent.construct_from(id: "pi_#{status}", status: status, amount: 1599, amount_received: 0,
                                           created: 0)
    end

    %w[requires_payment_method canceled].each do |status|
      it "treats #{status} as a retryable decline: nothing was collected" do
        allow(stripe.payment_intents).to receive(:create).and_return(intent(status))

        expect { adapter.capture(checkout_mandate) }
          .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
            expect(e).to be_retryable
          }
      end
    end

    %w[processing requires_action requires_confirmation requires_capture].each do |status|
      it "treats #{status} as an unknown outcome that must not be retried" do
        allow(stripe.payment_intents).to receive(:create).and_return(intent(status))

        expect { adapter.capture(checkout_mandate) }
          .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
            expect(e).not_to be_retryable
          }
      end
    end
  end

  # A charge failure surfaces as a PSP-agnostic PaymentFailed with a human-safe
  # message, so the executor renders a typed `payment_failed` 402.
  describe '#capture when the charge fails at Stripe' do
    include_context 'with a Stripe adapter'

    before { stub_cards('pm_default_visa') }

    it 'translates a Stripe::CardError (declined) into a RETRYABLE PaymentFailed with a safe message' do
      allow(stripe.payment_intents).to receive(:create)
        .and_raise(Stripe::CardError.new('Your card was declined.', nil, code: 'card_declined'))

      expect { adapter.capture(checkout_mandate) }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e).to be_retryable
          expect(e.message).to eq('the payment method was declined')
          # No raw Stripe text leaks through.
          expect(e.message).not_to include('Your card was declined')
        }
    end

    it 'maps authentication_required to a distinct human-safe message (still retryable)' do
      allow(stripe.payment_intents).to receive(:create)
        .and_raise(Stripe::CardError.new('auth', nil, code: 'authentication_required'))

      expect { adapter.capture(checkout_mandate) }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e).to be_retryable
          expect(e.message).to match(/authentication/i)
        }
    end
  end

  describe '#capture when Stripe cannot confirm the charge' do
    include_context 'with a Stripe adapter'

    before { stub_cards('pm_default_visa') }

    it 'translates a non-card Stripe error (timeout/connectivity) into a NON-retryable PaymentFailed (unknown outcome)' do
      allow(stripe.payment_intents).to receive(:create)
        .and_raise(Stripe::APIConnectionError.new('timed out'))

      expect { adapter.capture(checkout_mandate) }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e).not_to be_retryable
          expect(e.message).to match(/unknown/i)
          expect(e.message).not_to include('timed out')
        }
    end
  end
end
