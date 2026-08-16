# frozen_string_literal: true

# A hold on ONE fleet vehicle for one principal. `status` moves
# reserved → active the moment a rental token is issued for it — by
# `start_rental` for a licence-free scooter, by `rent_motorcycle` for the
# KYC-gated one — and never moves back, which is what makes a second
# activation of the same row a refusal rather than a second unlock token.
class Reservation < ApplicationRecord
  # The two states a reservation is ever written with. `reserved` is what
  # `reserve` creates and the ONLY state either rental verb will activate;
  # `active` is what activation writes.
  RESERVED = "reserved"
  ACTIVE   = "active"

  belongs_to :user
  belongs_to :scooter

  # The rows a rental verb may still activate. Both verbs require it, so it is
  # written once: a reservation already `active` (a ride in progress) is not
  # startable again, and answering that with the SAME refusal as "not yours"
  # is deliberate — see RentalGates.
  scope :still_reserved, -> { where(status: RESERVED) }

  # ── THE isolation predicate ────────────────────────────────────────────────
  # When skooti's handlers stopped writing SQL (K-654) this is the one fragment
  # that deliberately did NOT become a Ruby comparison, for the reason the
  # philslist pilot settled (see also Booking#owned_by_current_principal in
  # hoteling).
  #
  # `kiosk.current_user_id()` is a STABLE Postgres function reading the
  # transaction-local GUC `app.current_user_id`, which kiosk-server's
  # SessionContext sets with `SET LOCAL` — from the identity the wire resolved,
  # inside the very transaction the request runs in — and which evaporates at
  # COMMIT. A `where(user_id: <a ruby value>)` would be just as unforgeable
  # here; what it would cost is the part that generalises. Spec §7 makes
  # DB-enforced identity scoping a MUST, and this is the seam where the
  # app-layer predicate and the optional DB-layer RLS policy are literally the
  # same expression. A demo is the reference other operators copy.
  #
  # `Arel.sql` over a frozen literal rather than an interpolated string: there
  # is no caller-controlled value anywhere in this fragment. That is what makes
  # it exempt from the no-raw-SQL rule rather than an exception to it.
  scope :owned_by_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }
end
