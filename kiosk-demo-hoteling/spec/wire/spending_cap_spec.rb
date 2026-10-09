# frozen_string_literal: true

require "wire_helper"

RSpec.describe "an assistant's spending cap", :wire do
  def cap!(guest, cents)
    ActiveRecord::Base.connection.exec_update("UPDATE kiosk.agents SET spending_cap_cents = $1 WHERE id = $2",
                                              "cap", [cents, guest.agent_id])
  end

  it "refuses the stay that would cross it, however the currency is spelled" do
    guest  = register
    first  = reserve(guest, check_in: Date.current + 90, check_out: Date.current + 92)
    second = reserve(guest, check_in: Date.current + 90, check_out: Date.current + 92)
    cap    = first["total_cents"] + second["total_cents"] - 1
    cap!(guest, cap)

    expect(pay(guest, first, currency: "eur").status).to eq(200)
    over = pay(guest, second, currency: "EUR")
    expect([over.status, over.body["code"]]).to eq([403, "spending_cap_exceeded"])
    expect(Kiosk::CartMandate.where(user_id: guest.user_id).count).to eq(1)

    cap!(guest, cap + 1)
    raised = pay(guest, second, currency: "EUR")
    expect([raised.status, raised.body["currency"]]).to eq([200, "eur"])
    expect(Kiosk::Settlement.where(user_id: guest.user_id).pluck(:currency)).to eq(%w[eur eur])
  end
end
