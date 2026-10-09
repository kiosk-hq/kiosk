# frozen_string_literal: true

require "test_helper"

class WalkthroughTest < WireTest
  test "bin/demo tours a running origin and books Alice one appointment" do
    assert system({ "SERVER_URL" => live_url }, "bin/demo", chdir: Rails.root, out: File::NULL), "bin/demo failed"
    assert_equal [User.find_by!(email: "alice@example.com").id], Appointment.pluck(:user_id)
  end
end
