# frozen_string_literal: true

# THE ONE WRITE BOTH RENTAL VERBS PERFORM: mint the Ed25519 rental token the
# lock verifies offline, and flip the reservation to `active`.
#
# WHY IT IS FACTORED OUT, and this is the sharpest reason anything in this demo
# is shared. The bytes {RentalTokenIssuer.issue} signs are a PHYSICAL-DEVICE
# contract (K-686): the same message layout is reproduced byte-for-byte in
# lib/lock_sim.rb, firmware/host_test.c and firmware/skooti_lock.ino, and
# `demo:kat` pins it as a frozen known-answer vector. `start_rental` and
# `rent_motorcycle` both mint one. Two call sites for that is two places a byte
# can change — and a change made in one of them signs tokens no provisioned lock
# will open, for one vehicle class only, which is the failure that shows up in
# the street rather than in CI. There is exactly one call site now.
#
# It is an Operation-shaped object rather than an `Operation` class because it
# is not a VERB: the wire never reaches it directly. It is the shared tail of
# two verbs, in the same relation to them that {ListAccess} is to tudu's four —
# and, like them, it answers with an {OperationResult} and renders nothing.
module RentalActivation
  # How long a minted token is good for. The issuer's own default is the same
  # 900 seconds and is the value that actually goes INTO the signed message;
  # this constant is what the response ECHOES as `exp`, which is the number the
  # assistant plans around. Written here rather than twice in two verbs.
  TTL_SECONDS = 900

  module_function

  # @param reservation [Reservation] already proved owned, reserved and paid for
  # @param scooter [Scooter] the vehicle the reservation names, read server-side
  # @param reservation_id [String] the CALLER's spelling of that id, already
  #   through {WireArguments.reservation_id}. It is what gets SIGNED, and it is
  #   deliberately not re-read off `reservation.id`: {UuidCheck}'s pattern is
  #   `\h`, which accepts either hex case, so a caller that echoed an uppercase
  #   id has always received a token naming it that way. Re-canonicalising it
  #   here would change the bytes a provisioned lock verifies, and a conversion
  #   does not get to change what a signature covers (K-686). The UPDATE below
  #   uses the ROW's id, which is the same row either way.
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

    # Mark the reservation active. `update_all` on the id, which is what the raw
    # UPDATE was: no `updated_at` touch (the raw statement did not write one
    # either), no callbacks, one statement. It runs inside the SessionContext
    # transaction the wire already opened, so it commits with the request.
    Reservation.where(id: reservation.id).update_all(status: Reservation::ACTIVE)

    OperationResult.ok({
      scooter_code: scooter.code,
      rental_token: token,
      exp:          now + TTL_SECONDS,
    })
  end
end
