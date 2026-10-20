# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe do
  # An assistant polls `payment_setup` while its human is at the hosted page, so
  # every poll must hand back the same link.
  describe '#setup_url reuse of an outstanding session (K-492)' do
    include_context 'with a Stripe adapter'

    it "returns the OPEN setup session's url and mints NOTHING when one is outstanding" do
      stub_listed_sessions(listed_session)
      allow(stripe.checkout.sessions).to receive(:create)

      expect(adapter.setup_url(user_id: 'user-1', return_url: return_url))
        .to eq('https://checkout.stripe.com/setup/OUTSTANDING')
      expect(stripe.checkout.sessions).to have_received(:list).with(customer: 'cus_existing', status: 'open', limit: 10)
      expect(stripe.checkout.sessions).not_to have_received(:create)
    end

    it 'returns the SAME url across repeated polls (the poll is side-effect-free)' do
      stub_listed_sessions(listed_session)
      allow(stripe.checkout.sessions).to receive(:create)

      urls = Array.new(5) { adapter.setup_url(user_id: 'user-1', return_url: return_url) }

      expect(urls.uniq.size).to eq(1)
      expect(stripe.checkout.sessions).not_to have_received(:create)
    end
  end

  describe '#setup_url with no reusable session listed' do
    include_context 'with a Stripe adapter'

    it 'mints a fresh session when the outstanding one targets a DIFFERENT success_url' do
      # An operator that re-pointed its origin must not hand the human a stale
      # return target.
      stub_listed_sessions(
        listed_session(success_url: "https://old-origin.example/kiosk/payment_setup/return?#{described_class::RETURN_QUERY}")
      )
      stub_fresh_session

      expect(adapter.setup_url(user_id: 'user-1', return_url: return_url)).to eq(fresh_url)
      expect(stripe.checkout.sessions).to have_received(:create)
    end

    it 'ignores a listed session that is not in setup mode' do
      stub_listed_sessions(listed_session(mode: 'payment'))
      stub_fresh_session

      expect(adapter.setup_url(user_id: 'user-1', return_url: return_url)).to eq(fresh_url)
      expect(stripe.checkout.sessions).to have_received(:create)
    end
  end

  # A fresh session looks exactly like the happy path on the wire, so the adapter
  # logs every case where it could not find out whether one was outstanding.
  describe '#setup_url when the outstanding-session lookup fails' do
    include_context 'with a Stripe adapter'

    before do
      allow(stripe.checkout.sessions).to receive(:list)
        .and_raise(Stripe::APIConnectionError.new('list timed out'))
    end

    it 'falls back to minting when the lookup itself fails (a probe must not start erroring)' do
      stub_fresh_session

      expect(adapter.setup_url(user_id: 'user-1', return_url: return_url)).to eq(fresh_url)
      expect(stripe.checkout.sessions).to have_received(:create)
    end

    it 'SAYS SO when the lookup failed, so the degrade is not mistaken for the happy path' do
      stub_fresh_session

      expect { adapter.setup_url(user_id: 'user-1', return_url: return_url) }
        .to output(/could not list open setup sessions.*setup_url changes between polls/m).to_stderr
    end
  end

  describe '#setup_url warnings on an ordinary lookup' do
    include_context 'with a Stripe adapter'

    before { stub_fresh_session }

    it 'says NOTHING on the ordinary no-session path (the log line means a real fault)' do
      stub_no_outstanding_session

      expect { adapter.setup_url(user_id: 'user-1', return_url: return_url) }.not_to output.to_stderr
    end

    # The lookup asks for one page, so the reusable session can be truncated off a full one.
    it 'SAYS SO when a FULL page came back with nothing reusable in it' do
      stub_listed_sessions(*Array.new(described_class::SETUP_SESSION_LIST_LIMIT) { listed_session(mode: 'payment') })

      expect { adapter.setup_url(user_id: 'user-1', return_url: return_url) }
        .to output(/full page of #{described_class::SETUP_SESSION_LIST_LIMIT} open.*setup_url may change/m).to_stderr
    end

    it 'stays quiet when a SHORT page came back with nothing reusable (nothing was truncated)' do
      stub_listed_sessions(*Array.new(described_class::SETUP_SESSION_LIST_LIMIT - 1) { listed_session(mode: 'payment') })

      expect { adapter.setup_url(user_id: 'user-1', return_url: return_url) }.not_to output.to_stderr
    end
  end
end
