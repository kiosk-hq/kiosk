# frozen_string_literal: true

require "test_helper"

class RedteamTest < WireTest
  test "every attack in script/redteam_suite.rb is blocked" do
    attacker = { "SERVER_URL" => live_url, "KIOSK_ISSUER" => live_url }
    assert system(attacker, RbConfig.ruby, "script/redteam_suite.rb", chdir: Rails.root), "the battery found a breach"
  end
end
