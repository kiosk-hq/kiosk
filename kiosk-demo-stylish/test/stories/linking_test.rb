# frozen_string_literal: true

require "test_helper"

class LinkingStory < StoryTest
  # The assistant asks the salon for a code to show its person.
  def asks_for_a_code(key)
    opened = assistant.device_authorization(client_id: "stylish-test", public_key: key.public_key.to_pem)
    assert_equal 200, opened.status, opened.body
    opened.body
  end

  def approves(person, user_code)
    session = signs_in(person)
    page = session.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
    session.post_form("/kiosk/oauth/device/verify", "user_code" => user_code, "decision" => "approve",
                                                    "authenticity_token" => session.csrf_token(page.body))
  end

  # The salon answers with the assistant's credential once its person has approved.
  def collects_credential(code, key)
    answer = Net::HTTP.post_form(URI("#{live_url}/kiosk/oauth/token"),
                                 grant_type: "urn:ietf:params:oauth:grant-type:device_code",
                                 device_code: code["device_code"], signed: Client.proof(live_url, key))
    JSON.parse(answer.body)
  end

  def unlinks(person, client)
    status, = signs_in(person).post_json("/kiosk/auth/unlink", { agent_id: client.principal.agent_id }, { session: true })
    assert_equal 204, status
  end

  def the_assistants_page(session) = session.get_html("/kiosk/auth/assistants")

  test "Alice approves the code her assistant shows her, and it books in her name" do
    key  = OpenSSL::PKey::RSA.generate(2048)
    code = asks_for_a_code(key)
    assert_equal "authorization_pending", collects_credential(code, key)["error"]

    assert_equal "200", approves(:alice, code["user_code"]).code
    travel code["interval"] + 1
    credential = collects_credential(code, key)
    assert credential["access_token"], credential

    alice = Client.new(assistant, Kiosk::TestHelpers::Assistant::Principal.new(agent_id: nil, user_id: nil,
                                                                               token: credential["access_token"], rsa_key: key))
    assert_equal account_of(:alice), alice.account
    assert_equal account_of(:alice), Appointment.find(alice.books["appointment_id"]).user_id
  end

  test "Alice's second assistant shares her bookings, and unlinking the first leaves the second" do
    first  = assistant_of(:alice)
    second = assistant_of(:alice)
    booked = first.books["appointment_id"]
    assert_equal [account_of(:alice)] * 2, [first.principal.user_id, second.principal.user_id]
    assert_equal [booked], second.appointments

    unlinks(:alice, first)
    assert first.signs_back_in.refused?(:not_found)
    assert second.signs_back_in.ok?
  end

  test "Alice names her assistant and caps its spending on the assistants page" do
    linked = assistant_of(:alice)
    alice  = signs_in(:alice)
    page   = the_assistants_page(alice)
    assert_includes page.body, linked.principal.agent_id

    renamed = alice.post_form("/kiosk/auth/assistants/update", "authenticity_token" => alice.csrf_token(page.body),
                                                               "agent_id" => linked.principal.agent_id,
                                                               "human_label" => "Alice booking bot",
                                                               "spending_cap_cents" => "12345")
    assert_equal "200", renamed.code
    page = the_assistants_page(alice)
    assert_includes page.body, "Alice booking bot"
    assert_includes page.body, "cap: 12345 cents"
  end
end
