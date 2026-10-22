# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policy do
  it 'always returns nil regardless of factors' do
    expect(described_class.new.challenge_for(identity: 'user-1', verb: :query, factors: Kiosk::Reputation::Factors.empty))
      .to be_nil
  end

  describe Kiosk::Reputation::Factors do
    describe '.empty' do
      it 'returns a Factors instance with all-nil fields' do
        expect(described_class.empty.to_h).to eq(settled_purchases_count: nil, settled_purchases_cents: nil, calls_since_proof: nil)
      end
    end
  end
end
