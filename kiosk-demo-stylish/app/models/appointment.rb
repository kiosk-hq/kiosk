# frozen_string_literal: true

class Appointment < ApplicationRecord
  belongs_to :user
  belongs_to :salon
  # The service booked from the salon's menu. Optional: legacy bookings that
  # predate the menu (or a bare salon_id booking) carry no service and no
  # captured price. The captured price_cents drives the owner's forecast.
  belongs_to :service, optional: true

  # ── THE two GUC-borne assertions ───────────────────────────────────────────
  # When stylish's handlers stopped writing SQL (K-654) every statement became
  # an ordinary relation EXCEPT these two, and the reason is the one philslist
  # settled (see Listing#owned_by_current_principal, the K-654 pilot).
  #
  # `kiosk.current_user_id()` and `kiosk.current_role()` are STABLE Postgres
  # functions reading the transaction-local GUCs `app.current_user_id` /
  # `app.current_role`. kiosk-server's SessionContext sets them with `SET LOCAL`,
  # from the identity the wire resolved, inside the very transaction the handler
  # runs in, and they evaporate at COMMIT. The mixin's `kiosk_identity` carries
  # the same two facts and would be just as unforgeable — what it would cost is
  # the part that generalises. Spec §7 makes DB-enforced identity scoping a MUST,
  # and these are the seam where the app-layer predicate and the optional
  # DB-layer RLS policy are LITERALLY the same expression. A demo is the
  # reference other operators copy, so the predicate stays written in the terms
  # an RLS policy is written in.
  #
  # `Arel.sql` over a frozen literal rather than an interpolated string: there is
  # no caller-controlled value anywhere in either fragment. That is what makes
  # them exempt from the no-raw-SQL rule rather than an exception to it — and it
  # is what replaced `appt_scope`, a WHERE clause the calendar used to BUILD as a
  # Ruby string and splice into `execute`.
  scope :owned_by_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }

  # The staff role the bound human's IdP supplied, as the DB sees it. Read here
  # rather than off `kiosk_identity` for the reason `salon_calendar` has always
  # recorded: the branch and the scope above then agree by construction (one
  # source, no drift), and it keeps answering when the query is reached outside a
  # wire request — an RLS journey test sets the four GUCs but has no
  # `kiosk_identity`. Returns nil when no session GUC is set.
  def self.current_principal_role
    connection.select_value("SELECT kiosk.current_role()")
  end
end
