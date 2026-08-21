# frozen_string_literal: true

class User < ApplicationRecord
  # Human account holders sign in with email + password (the session that
  # approves assistant links on the verify page). Assistant accounts are
  # rows in this same table WITHOUT credentials — kiosk-pop key possession
  # is their only channel, so they can never drive the human surfaces.
  devise :database_authenticatable

  # Appointments a customer booked for themselves.
  has_many :appointments, dependent: :destroy

  # Salon staff carry a role in the provider's own identity system
  # (staff_role: 'owner'). Customers and credential-less assistant accounts
  # have staff_role NULL. This column IS the role source for roles-from-IdP:
  # `#kiosk_role` below hands it to the Devise adapter.
  def staff? = staff_role.present?

  # roles-from-IdP over the REAL Devise session. The Devise user-IdP adapter
  # (kiosk-user-idp-devise) calls `user.kiosk_role` first when resolving the
  # role for a signed-in principal; without this opt-in it would fall back to
  # the first configured role (`:customer`), so a salon OWNER who signs in
  # through /users/sign_in — the real operator path — would mint link codes as
  # `customer` and see only their own bookings in `salon_calendar` (no whole
  # book, no forecast). Map the provider's own `staff_role` onto the kiosk role:
  # staff carry their staff_role ('owner'), everyone else is a 'customer' (the
  # registration default). The result is always one of `Kiosk.configuration.roles`
  # (%i[customer owner]) — and it is now that BY CONSTRUCTION rather than by
  # convention (K-712h). `staff_role` is a bare varchar with no CHECK
  # constraint, so before this the column's contents were returned verbatim as
  # the kiosk role: one stray value in the provider's own table and an
  # assistant would be minted at a role the origin never configured. An
  # unrecognised value now falls back to the LEAST privileged role rather than
  # being trusted, which is the only safe direction for an authorization input.
  # Since T-066 this is the ONLY channel: the `X-Staff-Session` SSO stand-in
  # that read the same column is gone, so this method is what makes
  # roles-from-IdP work at all.
  def kiosk_role
    return "customer" unless staff?

    Kiosk.configuration.roles.map(&:to_s).include?(staff_role) ? staff_role : "customer"
  end
end
