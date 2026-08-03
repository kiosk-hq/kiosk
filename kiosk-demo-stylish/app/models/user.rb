# frozen_string_literal: true

class User < ApplicationRecord
  # Human account holders sign in with email + password (the session that
  # approves assistant links on the verify page). Assistant accounts are
  # rows in this same table WITHOUT credentials — kiosk-pop key possession
  # is their only channel, so they can never drive the human surfaces.
  devise :database_authenticatable

  # Appointments a customer booked for themselves.
  has_many :appointments, dependent: :destroy

  # Appointments a STAFF member (staff_role owner/stylist) is the stylist
  # for — the calendar the `salon_calendar` query scopes on.
  has_many :staffed_appointments,
           class_name: "Appointment", foreign_key: :stylist_id, dependent: :nullify

  # Salon staff carry a role in the provider's own identity system
  # (staff_role: 'owner' | 'stylist'). Customers and credential-less
  # assistant accounts have staff_role NULL. Read by the StubUserIdp so the
  # session identity carries the staff member's role (roles-from-IdP).
  def staff? = staff_role.present?

  # roles-from-IdP over the REAL Devise session. The Devise user-IdP adapter
  # (kiosk-user-idp-devise) calls `user.kiosk_role` first when resolving the
  # role for a signed-in principal; without this opt-in it would fall back to
  # the first configured role (`:customer`), so a salon OWNER or STYLIST who
  # signs in through /users/sign_in — the real operator path — would mint link
  # codes as `customer` and see an empty `salon_calendar`. Map the provider's
  # own `staff_role` onto the kiosk role: staff carry their staff_role
  # ('owner'/'stylist'), everyone else is a 'customer' (the registration
  # default). The result is always one of `Kiosk.configuration.roles`
  # (%i[customer stylist owner]). This is the Devise-session twin of the read
  # StubUserIdp does off `staff_role` — the same role source, both channels.
  def kiosk_role = staff? ? staff_role : "customer"
end
