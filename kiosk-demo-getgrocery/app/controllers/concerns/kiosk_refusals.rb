# frozen_string_literal: true

# The HTTP half of getgrocery's Kiosk handlers: the one place an
# {OperationResult} becomes a response.
#
# WHY A CONCERN rather than a private renderer per controller. getgrocery's
# QUERY half and ACTION half refuse with the SAME sentences — "missing field: …"
# reaches both, and the Dublin-zone rejection reaches `delivery_slots` (a query),
# `create_order` and `reschedule_delivery` (both actions) word for word, because
# an address is checked wherever one is taken. What is shared is split the way
# tudu, hoteling and skooti split it: the ANSWER (the refusal and its sentence)
# is {WireArguments}/{OperationResult}, which render nothing and are therefore
# reachable from the Operations too; what is left here is the part that
# genuinely needs a controller, because it calls `render`.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# (K-495: the operator owns the structure).
module KioskRefusals
  extend ActiveSupport::Concern

  private

  # Render whatever an Operation (or a shape guard) answered. Success renders
  # the value as-is — the caller already built it in the exact shape the wire
  # publishes — and a refusal becomes the coded envelope below.
  def render_operation(result)
    return render json: result.value if result.ok?

    render_refusal(result)
  end

  # A plain `render json:, status:` naming a code from the wire's closed
  # vocabulary. Naming it is what lets an assistant branch; the status alone
  # would already imply `bad_request`/`forbidden`/`not_found`, but `kyc_required`
  # SHARES 403 with `forbidden` and a bare status cannot tell them apart — so
  # for getgrocery writing the code is not merely explicit, it is the only way
  # the age gate's refusal survives the trip. A nil hint is dropped, so a refusal
  # with nothing to add carries no empty field — which is what keeps these
  # byte-identical to the `Errors::` envelopes they replace.
  def render_refusal(result)
    render json: { error: { code: result.code, message: result.message, hint: result.hint }.compact },
           status: result.status
  end
end
