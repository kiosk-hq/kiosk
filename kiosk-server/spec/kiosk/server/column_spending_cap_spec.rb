# frozen_string_literal: true

RSpec.shared_context 'column spending cap spec: seam' do
  let(:conn) { FakeConnection.new }
  subject(:seam) { described_class.new }

  before do
    Kiosk.configure { |c| c.schema = 'kiosk' }
    allow(ActiveRecord::Base).to receive(:lease_connection).and_return(conn)
  end
end

RSpec.describe Kiosk::Server::ColumnSpendingCap, 'reading the cap' do
  include_context 'column spending cap spec: seam'

  it 'reads the per-assistant cap and its currency from agents (live rows only)' do
    conn.next_exec_result = [{ 'spending_cap_cents' => 2500, 'spending_cap_currency' => 'eur' }]
    expect(seam.call(agent_id: 'a-1')).to eq(amount_cents: 2500, currency: 'eur')
    sql, binds = conn.bound(/SELECT/i).first
    expect(sql).to include('spending_cap_cents, spending_cap_currency')
    expect(sql).to include('"kiosk".agents')
    expect(sql).to include('revoked_at IS NULL')
    # The agent id is `$1`, not a quoted literal. Only the SCHEMA is
    # interpolated — an operator-set identifier Postgres cannot bind.
    expect(sql).to include('WHERE id = $1')
    expect(binds).to eq(['a-1'])
    expect(sql).not_to include('a-1')
  end
end

RSpec.describe Kiosk::Server::ColumnSpendingCap, 'without a cap' do
  include_context 'column spending cap spec: seam'

  it 'returns nil when the assistant row has no cap set (unlimited)' do
    conn.next_exec_result = [{ 'spending_cap_cents' => nil, 'spending_cap_currency' => nil }]
    expect(seam.call(agent_id: 'a-1')).to be_nil
  end

  it 'returns nil for an unknown or revoked key (no row)' do
    conn.next_exec_result = []
    expect(seam.call(agent_id: 'ghost')).to be_nil
  end

  it 'returns nil for a nil agent_id without hitting the DB' do
    expect(seam.call(agent_id: nil)).to be_nil
    expect(conn.exec_queries).to be_empty
  end

  it 'coerces the stored cap to an integer' do
    conn.next_exec_result = [{ 'spending_cap_cents' => '3000', 'spending_cap_currency' => 'eur' }]
    expect(seam.call(agent_id: 'a-1')).to eq(amount_cents: 3000, currency: 'eur')
  end
end
