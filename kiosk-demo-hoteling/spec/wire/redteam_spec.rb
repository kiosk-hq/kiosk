# frozen_string_literal: true

require "wire_helper"

RSpec.describe "script/redteam_suite.rb", :wire do
  it "finds every attack blocked" do
    attacker = { "SERVER_URL" => live_url, "KIOSK_ISSUER" => live_url }
    expect(system(attacker, RbConfig.ruby, "script/redteam_suite.rb", chdir: Rails.root)).to be(true)
  end
end
