# frozen_string_literal: true

# The HTTP half of tudu's Kiosk handlers: the one place an {OperationResult}
# becomes a response.
#
# WHY A CONCERN rather than a four-line `render_bad_request` copied into each
# controller. tudu's QUERY half refuses as well as its action half, and the two
# halves refuse the SAME WAY. What is shared is split in two: the ANSWER (shape
# check, membership predicate, and the sentence each refusal carries) is
# {ListAccess}, which renders nothing and is therefore reachable from the
# Operations and the human web controllers as well; what is left here is the part
# that genuinely needs a controller, because it calls `render`.
#
# WHY IT IS ITS OWN FILE, under the same name the other six demos use.
# `bin/check-demo-copies` pairs copies by RELATIVE PATH, so the same two
# renderers parked under a name only tudu uses — folded into
# {KioskMembershipGate}, say — are compared to nothing and free to drift from
# the fleet's while every check stays green. Keeping the file here is what puts
# all seven under the gate; the membership guard stays next door, because it is
# tudu's alone.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# — the operator owns the structure. A gem-level
# `render_kiosk_error(code:, message:)` would cover `render_refusal` below and
# nothing else, so it is not proposed here.
module KioskRefusals
  extend ActiveSupport::Concern

  private

  # Render whatever an Operation (or a shape guard) answered. Success renders
  # the value as-is — the Operation already built it string-keyed in the exact
  # shape the wire publishes — and a refusal becomes the coded envelope below.
  def render_operation(result)
    return render json: result.value if result.ok?

    render_refusal(result)
  end

  # A plain `render json:, status:` naming a code from the wire's closed
  # vocabulary. Naming it is what lets an assistant branch; the status alone
  # would already imply each of these, but writing it keeps the answer explicit.
  # A nil hint is dropped, so a refusal that has nothing to add carries no empty
  # field.
  def render_refusal(result)
    render json: { error: { code: result.code, message: result.message, hint: result.hint }.compact },
           status: result.status
  end
end
