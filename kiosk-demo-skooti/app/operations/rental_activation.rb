# frozen_string_literal: true

# THE ONE WRITE BOTH RENTAL VERBS PERFORM: mint the Ed25519 rental token the
# lock verifies offline, and flip the reservation to `active`.
#
# ONE call site, deliberately. The bytes {RentalTokenIssuer.issue} signs are a
# PHYSICAL-DEVICE contract (K-686) reproduced byte-for-byte in script/lock_sim.rb,
# firmware/host_test.c and firmware/skooti_lock.ino and pinned by `demo:kat` as a
# frozen known-answer vector. Both rental verbs mint one, so a second call site
# would be a second place a byte can drift — and that drift signs tokens no
# provisioned lock opens, for one vehicle class only.
#
# Not a VERB: the wire never reaches it — it is the shared tail of two verbs.
module RentalActivation
  # The issuer's own default is the same 900 seconds and is what goes INTO the
  # signed message; this constant is what the response ECHOES as `exp`.
  TTL_SECONDS = 900

  module_function

  # @param reservation [Reservation] already proved owned, reserved and paid for
  # @param scooter [Scooter] the vehicle the reservation names, read server-side
  # @param reservation_id [String] the CALLER's spelling of that id, already
  #   through {WireArguments.reservation_id}. It is what gets SIGNED, and is
  #   deliberately not re-read off `reservation.id`: {UuidCheck}'s `\h` pattern
  #   accepts either hex case, so an uppercase id is signed as the caller wrote
  #   it and re-canonicalising here would change the bytes a provisioned lock
  #   verifies (K-686). The UPDATE below uses the ROW's id — the same row.
  # @return [OperationResult] the token, the vehicle it opens, and its expiry
  def call(reservation:, scooter:, reservation_id:)
    now = Time.now.to_i

    # Bound to the SERVER-DERIVED vehicle code, never to a client value — the
    # cross-vehicle unlock defence.
    token = RentalTokenIssuer.issue(
      scooter_code:   scooter.code,
      reservation_id: reservation_id.to_s,
      now:            now,
    )

    # `update_all`: no callbacks, no `updated_at` touch, one statement. It runs
    # inside the SessionContext transaction the wire opened, so it commits with
    # the request.
    Reservation.where(id: reservation.id).update_all(status: Reservation::ACTIVE)

    OperationResult.ok({
      scooter_code: scooter.code,
      rental_token: token,
      exp:          now + TTL_SECONDS,
    })
  end
end
