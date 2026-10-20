# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe do
  describe '#refund' do
    include_context 'with a Stripe adapter'

    it 'reverses the named PaymentIntent for the amount, keyed by the charge and the refund' do
      refund = Stripe::Refund.construct_from(id: 're_123', amount: 1599, created: 1_700_000_100)
      allow(stripe.refunds).to receive(:create).and_return(refund)

      expect(adapter.refund(psp_reference: 'pi_123', amount_cents: 1599, key: 'order-7')).to eq(
        psp_reference: 're_123',
        refunded_psp_reference: 'pi_123',
        refunded_amount_cents: 1599,
        refunded_at: Time.at(1_700_000_100).utc
      )
      expect(stripe.refunds).to have_received(:create).with(
        { payment_intent: 'pi_123', amount: 1599 },
        { idempotency_key: 'pi_123-refund-order-7' }
      )
    end

    it "answers PaymentFailed when Stripe cannot refund, without Stripe's text" do
      allow(stripe.refunds).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new('Charge ch_1 has already been refunded.', nil))

      expect { adapter.refund(psp_reference: 'pi_123', amount_cents: 1599, key: 'order-7') }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e.message).not_to include('ch_1')
        }
    end
  end

  describe '#refund against stripe-mock' do
    include_context 'with a Stripe adapter'

    # The idempotency key of every refund request the SDK sends.
    def refund_keys
      keys = []
      subscriber = Stripe::Instrumentation.subscribe(:request_end, :refund_keys) do |event|
        keys << event.request_header['Idempotency-Key'] if event.path == '/v1/refunds'
      end
      yield
      keys
    ensure
      Stripe::Instrumentation.unsubscribe(:request_end, subscriber)
    end

    it 'refunds a charge against stripe-mock' do
      with_stripe_mock do |mocked|
        receipt = mocked.refund(psp_reference: 'pi_123', amount_cents: 1599, key: 'order-7')
        expect(receipt[:psp_reference]).to start_with('re_')
        expect(receipt[:refunded_psp_reference]).to eq('pi_123')
      end
    end

    it 'sends each refund of one charge under its own key, and a repeat under the same key' do
      with_stripe_mock do |mocked|
        keys = refund_keys do
          mocked.refund(psp_reference: 'pi_123', amount_cents: 500, key: 'line-1')
          mocked.refund(psp_reference: 'pi_123', amount_cents: 700, key: 'line-2')
          mocked.refund(psp_reference: 'pi_123', amount_cents: 700, key: 'line-2')
        end

        expect(keys).to eq(%w[pi_123-refund-line-1 pi_123-refund-line-2 pi_123-refund-line-2])
      end
    end
  end
end
