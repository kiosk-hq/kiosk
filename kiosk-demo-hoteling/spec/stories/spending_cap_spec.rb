# frozen_string_literal: true

require "story_helper"

RSpec.describe "An assistant's spending cap", type: :story do
  def the_hotel_caps_spending(of:, at:)
    ActiveRecord::Base.connection.exec_update("UPDATE kiosk.agents SET spending_cap_cents = $1 WHERE id = $2",
                                              "cap", [at, of.principal.agent_id])
  end

  it "a guest's assistant cannot pay for the stay that would cross its cap, however the currency is spelled, until the cap is raised" do
    guest  = a_guest
    first  = guest.reserves(check_in: Date.current + 90, check_out: Date.current + 92)
    second = guest.reserves(check_in: Date.current + 90, check_out: Date.current + 92)
    cap    = first["total_cents"] + second["total_cents"] - 1
    the_hotel_caps_spending(of: guest, at: cap)

    expect(guest.pays_for(first, currency: "eur")).to be_ok
    expect(guest.pays_for(second, currency: "EUR")).to be_refused(:spending_cap_exceeded)
    expect(Kiosk::CartMandate.where(user_id: guest.principal.user_id).count).to eq(1)

    the_hotel_caps_spending(of: guest, at: cap + 1)
    raised = guest.pays_for(second, currency: "EUR")
    expect(raised).to be_ok, raised.to_s
    expect(raised["currency"]).to eq("eur")
    expect(Kiosk::Settlement.where(user_id: guest.principal.user_id).pluck(:currency)).to eq(%w[eur eur])
  end
end
