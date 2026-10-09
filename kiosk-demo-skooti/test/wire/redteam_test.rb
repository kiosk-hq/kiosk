# frozen_string_literal: true

require "test_helper"
require_relative "../prove_broker"

class RedteamTest < WireTest
  setup { ProveBroker.start }

  test "every attack in script/redteam_suite.rb is blocked" do
    attacker = { "SERVER_URL" => live_url, "KIOSK_ISSUER" => live_url,
                 "RIDER_EMAIL" => "ada@example.com", "DEMO_PASSWORD" => "skooti-demo-password" }
    assert system(attacker, RbConfig.ruby, "script/redteam_suite.rb", chdir: Rails.root), "the battery found a breach"
  end
end
