# frozen_string_literal: true

# Spec Section 8.5.5: delivery is ordered per origin. A pubsub that hands
# events over on one thread (solid_cable) keeps that order only when the
# channel delivers on that thread, not on Action Cable's worker pool.
RSpec.describe KioskEvents do
  it 'delivers a live event on the thread the pubsub calls it on' do
    delivered_on = nil
    handler = described_class.allocate.send(
      :worker_pool_stream_handler, 'kiosk:events:u1:todo', ->(_event) { delivered_on = Thread.current }, coder: nil
    )
    handler.call('{}')

    expect(delivered_on).to eq(Thread.current)
  end
end
