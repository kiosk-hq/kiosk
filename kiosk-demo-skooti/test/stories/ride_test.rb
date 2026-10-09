# frozen_string_literal: true

require "test_helper"

class RideStory < StoryTest
  def tamper(token) = token.sub(/.\z/) { _1 == "A" ? "B" : "A" }

  # The page the rider opens on the phone shows the QR code and the token the lock takes.
  def opens_unlock_page(rental)
    page = Net::HTTP.get_response(URI(rental["unlock_url"]))
    assert_equal "200", page.code
    page.body
  end

  test "a rider with no account reserves a scooter nearby, pays for the first minute and unlocks it" do
    rider = a_rider
    assert_includes rider.vehicles_nearby.pluck("code"), "SK-001"

    scooter = rider.reserves("SK-001")
    assert scooter.ok?, scooter
    assert_equal "ready", rider.sets_up_payment["status"]
    assert rider.pays_for(scooter).ok?

    rental = rider.rides(scooter)
    assert rental.ok?, rental
    assert_predicate Reservation.find(scooter["reservation_id"]), :active?
    assert_equal 1, Kiosk::Settlement.where(user_id: rider.principal.user_id).count
    assert_equal rental["rental_token"].rpartition(".").first.split("|")[4].to_i, rental["exp"]

    page = opens_unlock_page(rental)
    assert_includes page, UnlockLink.svg(rental["unlock_url"])
    assert_includes page, rental["rental_token"]
    assert the_lock_on("SK-001").unlock(token: rental["rental_token"], now: Time.now.to_i)
  end

  test "the lock opens only this scooter, only before the rental expires, only with skooti's signature, and only once" do
    rider = a_rider
    scooter = rider.reserves("SK-001")
    assert rider.pays_for(scooter).ok?
    rental = rider.rides(scooter)
    token, now = rental["rental_token"], Time.now.to_i

    assert_not the_lock_on("SK-001").unlock(token:, now: rental["exp"] + 1), "expired"
    assert_not the_lock_on("SK-999").unlock(token:, now:), "another scooter"
    assert_not the_lock_on("SK-001").unlock(token: tamper(token), now:), "forged signature"
    lock = the_lock_on("SK-001")
    assert lock.unlock(token:, now:)
    assert_not lock.unlock(token:, now:), "replayed"
  end

  test "a scooter does not start before it is paid for, and the rider is told to pay first" do
    rider = a_rider
    scooter = rider.reserves("SK-001")
    assert_equal "ready", rider.sets_up_payment["status"]

    refused = rider.rides(scooter)
    assert refused.refused?(:forbidden), refused
    assert_includes refused["detail"], "pay for it first"
    assert_includes refused["detail"], "/pay"
  end

  test "a rider's reservations list shows what they reserved" do
    rider = a_rider
    assert_empty rider.reservations

    scooter = rider.reserves("SK-001")
    assert_equal [scooter["reservation_id"]], rider.reservations.pluck("reservation_id")
  end

  test "the demo's rental script rents a scooter whose token bin/make-qr and bin/ble-unlock hand to a real lock" do
    output = IO.popen({ "SERVER_URL" => live_url }, [RbConfig.ruby, "script/rental_flow.rb"], chdir: Rails.root, &:read)
    assert_predicate $?, :success?
    assert the_lock_on("SK-001").unlock(token: JSON.parse(output).fetch("rental_token"), now: Time.now.to_i)
  end
end
