# frozen_string_literal: true

RSpec.describe Kiosk::Server::ColumnSpendingCap do
  let(:conn) { FakeConnection.new }
  subject(:seam) { described_class.new(schema: "kiosk", connection: conn) }

  it "reads the per-assistant cap from agents.spending_cap_cents (live rows only)" do
    conn.next_exec_result = [{ "spending_cap_cents" => 2500 }]
    expect(seam.call(agent_id: "a-1")).to eq(2500)
    sql, binds = conn.bound(/SELECT/i).first
    expect(sql).to include("spending_cap_cents")
    expect(sql).to include('"kiosk".agents')
    expect(sql).to include("revoked_at IS NULL")
    # K-782: the agent id is `$1`, not a quoted literal. Only the SCHEMA is
    # interpolated — an operator-set identifier Postgres cannot bind.
    expect(sql).to include("WHERE id = $1")
    expect(binds).to eq(["a-1"])
    expect(sql).not_to include("a-1")
  end

  it "returns nil when the assistant row has no cap set (unlimited)" do
    conn.next_exec_result = [{ "spending_cap_cents" => nil }]
    expect(seam.call(agent_id: "a-1")).to be_nil
  end

  it "returns nil for an unknown or revoked key (no row)" do
    conn.next_exec_result = []
    expect(seam.call(agent_id: "ghost")).to be_nil
  end

  it "returns nil for a nil agent_id without hitting the DB" do
    expect(seam.call(agent_id: nil)).to be_nil
    expect(conn.exec_queries).to be_empty
  end

  it "coerces the stored cap to an integer" do
    conn.next_exec_result = [{ "spending_cap_cents" => "3000" }]
    expect(seam.call(agent_id: "a-1")).to eq(3000)
  end
end
