# frozen_string_literal: true

require "test_helper"

class RentalTest < WireTest
  test "a paid reservation of a licence-free scooter becomes a rental the lock opens once" do
    rider = register
    assert_includes assistant.query(rider, name: "scooters_available").body.map { _1["code"] }, "SK-001"

    reservation = reserve(rider, "SK-001")
    setup = assistant.run(rider, name: "payment_setup")
    assert_equal [200, "ready"], [setup.status, setup.body["status"]]
    assert_equal 200, pay(rider, reservation).status

    rental = assistant.run(rider, name: "start_rental", reservation_id: reservation["reservation_id"])
    assert_equal 200, rental.status, rental.body
    token = rental.body["rental_token"]
    assert_equal token.rpartition(".").first.split("|")[4].to_i, rental.body["exp"]
    assert_predicate Reservation.find(reservation["reservation_id"]), :active?
    assert_equal 1, Kiosk::Settlement.where(user_id: rider.user_id).count

    page = Net::HTTP.get_response(URI(rental.body["unlock_url"]))
    assert_equal "200", page.code
    assert_includes page.body, UnlockLink.svg(rental.body["unlock_url"])
    assert_includes page.body, token

    now = Time.now.to_i
    assert_not lock("SK-001").unlock(token:, now: rental.body["exp"] + 1), "expired"
    assert_not lock("SK-999").unlock(token:, now:), "another scooter"
    assert_not lock("SK-001").unlock(token: token.sub(/.\z/) { _1 == "A" ? "B" : "A" }, now:), "forged signature"
    once = lock("SK-001")
    assert once.unlock(token:, now:)
    assert_not once.unlock(token:, now:), "replayed"
  end

  test "script/rental_flow.rb rents a scooter for bin/make-qr and bin/ble-unlock" do
    output = IO.popen({ "SERVER_URL" => live_url }, [RbConfig.ruby, "script/rental_flow.rb"], chdir: Rails.root, &:read)
    assert_predicate $?, :success?
    assert lock("SK-001").unlock(token: JSON.parse(output).fetch("rental_token"), now: Time.now.to_i)
  end

  test "an unpaid reservation does not start, and the refusal says to pay first" do
    rider = register
    reservation = reserve(rider, "SK-001")
    setup = assistant.run(rider, name: "payment_setup")
    assert_equal [200, "ready"], [setup.status, setup.body["status"]]

    refusal = assistant.run(rider, name: "start_rental", reservation_id: reservation["reservation_id"])
    assert_equal 403, refusal.status
    assert_includes refusal.body["detail"], "pay for it first"
    assert_includes refusal.body["detail"], "/pay"
  end

  test "my_reservations lists the caller's own reservations" do
    rider = register
    assert_empty assistant.query(rider, name: "my_reservations").body

    reservation = reserve(rider, "SK-001")
    listed = assistant.query(rider, name: "my_reservations").body
    assert_equal [reservation["reservation_id"]], listed.map { _1["reservation_id"] }
  end
end
