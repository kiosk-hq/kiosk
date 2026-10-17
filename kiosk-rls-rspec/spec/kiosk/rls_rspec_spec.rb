# frozen_string_literal: true

RSpec.describe Kiosk::RLSRSpec, 'JOURNEY_TYPES' do
  it 'declares both kiosk_journey and kiosk_agent' do
    expect(described_class::JOURNEY_TYPES).to eq(%i[kiosk_journey kiosk_agent])
  end
end

RSpec.describe Kiosk::RLSRSpec, 'type: :kiosk_journey example group', type: :kiosk_journey do
  let(:alice) { FakeUser.new('u-alice', 'customer') }

  before { Kiosk.configure { |c| c.roles = %i[customer] } }

  it 'has the journey helpers available' do
    helpers = %i[as_agent_of as_user as_agent as_anonymous
                 query run_query run_action pay_action kiosk_seed]

    # The list is written by hand, so compare it with the module: a
    # `respond_to` over a short list passes even when a helper is missing.
    expect(helpers).to match_array(Kiosk::TestHelpers::Journey.public_instance_methods(false))
    expect(self).to respond_to(*helpers)
  end

  it 'as_agent_of yields under an agent identity' do
    observed = nil
    as_agent_of(alice) { observed = Kiosk::TestHelpers.executor.current_identity }
    expect(observed.actor).to    eq('agent')
    expect(observed.user_id).to  eq('u-alice')
  end
end

RSpec.describe Kiosk::RLSRSpec, 'type: :kiosk_agent example group', type: :kiosk_agent do
  it 'shares the same journey-DSL surface' do
    # Ask the module for the whole surface: sampled names cannot tell a shared
    # surface from a subset of it.
    expect(self).to respond_to(*Kiosk::TestHelpers::Journey.public_instance_methods(false))
  end
end

RSpec.describe Kiosk::RLSRSpec, '.install!' do
  it 'is idempotent (re-running adds duplicates but the include is harmless)' do
    expect { described_class.install! }.not_to raise_error
  end
end
