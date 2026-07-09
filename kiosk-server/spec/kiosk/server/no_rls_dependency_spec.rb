# frozen_string_literal: true

RSpec.describe "kiosk-server without kiosk-rls" do
  it "does not load Kiosk::RLS (RLS is opt-in via the kiosk-rls gem)" do
    expect(defined?(Kiosk::RLS)).to be_nil
  end
end
