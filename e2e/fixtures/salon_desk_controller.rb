# frozen_string_literal: true

# THE SALON'S BACK OFFICE — an operator-side surface, NOT a Kiosk verb.
#
# It exists so this harness can prove the one thing an event stream is for:
# a transition the assistant did not ask for. Everything else on this origin
# answers a call; this answers a salon looking at its book.
#
# It is deliberately NOT in `c.handlers` and NOT drawn under the mount. An
# operator's own pages are its own business — the wire neither knows nor cares
# that this is what moved the row — and putting it on the wire would teach the
# opposite: that a push has to be paired with a verb.
#
# It is also not authenticated, because this is a test harness and the surface
# stands in for a logged-in salon employee. An operator's real back office is
# behind their own session; nothing here is a claim about that.
class SalonDeskController < ApplicationController
  # The harness drives this with `curl`, and ApplicationController is a real
  # ActionController::Base with Rails' forgery protection on — which is what a
  # salon's actual back office wants, behind a signed-in session and a form
  # token. There is no session here and nothing to protect: this stands in for
  # the employee, and the harness IS the employee.
  skip_forgery_protection

  def confirm
    appointment = Appointment.find_by(id: params[:appointment_id])
    return head(:not_found) unless appointment
    # Confirming twice is a no-op rather than a second announcement: the salon
    # said yes once, and an assistant that reconnects must not be told again.
    return head(:ok) if appointment.confirmed_at

    appointment.update!(confirmed_at: Time.current)

    # THE AUDIENCE IS THE OWNER, and it is named rather than derived from a
    # request: there is no request here that belongs to the guest. The subject
    # is the appointment, so a subscriber may narrow to one row.
    Kiosk::Server::Events.emit(
      topic:          :appointment_confirmed,
      subject:        appointment.id,
      identity_scope: [appointment.user_id],
      data:           { "appointment_id" => appointment.id,
                        "salon_id"       => appointment.salon_id,
                        "slot"           => appointment.slot.utc.iso8601 },
    )

    head :ok
  end
end
