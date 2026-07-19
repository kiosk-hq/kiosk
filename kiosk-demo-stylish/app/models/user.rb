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
end
