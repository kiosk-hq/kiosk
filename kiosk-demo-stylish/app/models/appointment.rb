# frozen_string_literal: true

class Appointment < ApplicationRecord
  include Kiosk::Owned

  belongs_to :user
  belongs_to :salon
  # The service booked from the salon's menu. Optional: a bare salon booking
  # names no service and captures no price. The captured price_cents drives the
  # owner's forecast.
  belongs_to :service, optional: true


  # The staff role the bound human's IdP supplied, as the DB sees it. Read here
  # rather than off `kiosk_identity` so that the branch and the scope above
  # agree by construction (one source, no drift), and so it keeps answering when
  # the query is reached outside a wire request — an RLS journey test sets the
  # four GUCs but has no `kiosk_identity`. Returns nil when no session GUC is
  # set.
  def self.current_principal_role
    connection.select_value("SELECT kiosk.current_role()")
  end
end
