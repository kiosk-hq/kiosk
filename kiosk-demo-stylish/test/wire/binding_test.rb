# frozen_string_literal: true

require "test_helper"

# A human signed in on the Devise form binds assistants to their own account.
class BindingTest < WireTest
  GRANT = "urn:ietf:params:oauth:grant-type:device_code"

  def alice = User.find_by!(email: "alice@example.com")

  def poll(device_code, key)
    Net::HTTP.post_form(URI("#{live_url}/kiosk/oauth/token"), grant_type: GRANT, device_code:, signed: proof(key))
  end

  def approve(human, user_code)
    page = human.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
    human.post_form("/kiosk/oauth/device/verify", "user_code" => user_code, "decision" => "approve",
                                                  "authenticity_token" => human.csrf_token(page.body))
  end

  test "an assistant the human approves on the verify page acts as that human" do
    key = OpenSSL::PKey::RSA.generate(2048)
    opened = client.device_authorization(client_id: "stylish-test", public_key: key.public_key.to_pem)
    assert_equal 200, opened.status
    assert_empty %w[device_code user_code verification_uri expires_in interval] - opened.body.keys

    pending = poll(opened.body["device_code"], key)
    assert_equal ["400", "authorization_pending"], [pending.code, JSON.parse(pending.body)["error"]]

    assert_equal "200", approve(sign_in("alice@example.com"), opened.body["user_code"]).code
    travel opened.body["interval"] + 1
    granted = poll(opened.body["device_code"], key)
    assert_equal "200", granted.code, granted.body

    token = JSON.parse(granted.body)["access_token"]
    assistant = Kiosk::TestHelpers::Assistant::Principal.new(agent_id: nil, user_id: nil, token:, rsa_key: key)
    assert_equal alice.id, claims(assistant)["sub"]
    assert_equal alice.id, Appointment.find(book(assistant)["appointment_id"]).user_id
  end

  test "a second assistant shares the account, and unlinking the first leaves the second" do
    first  = bind("alice@example.com")
    second = bind("alice@example.com")
    booked = book(first)["appointment_id"]
    assert_equal [alice.id] * 2, [first.user_id, second.user_id]
    assert_equal [booked], my_appointments(second)

    status, = sign_in("alice@example.com").post_json("/kiosk/auth/unlink", { agent_id: first.agent_id }, { session: true })
    assert_equal 204, status
    assert_equal [404, 200], [login(first), login(second)]
  end

  test "the human names and caps an assistant on the manage page" do
    assistant = bind("alice@example.com")
    human = sign_in("alice@example.com")
    page = human.get_html("/kiosk/auth/assistants")
    assert_includes page.body, assistant.agent_id

    updated = human.post_form("/kiosk/auth/assistants/update", "authenticity_token" => human.csrf_token(page.body),
                                                               "agent_id" => assistant.agent_id,
                                                               "human_label" => "Alice booking bot",
                                                               "spending_cap_cents" => "12345")
    assert_equal "200", updated.code
    page = human.get_html("/kiosk/auth/assistants")
    assert_includes page.body, "Alice booking bot"
    assert_includes page.body, "cap: 12345 cents"
  end
end
