# frozen_string_literal: true

# The HTTP half of hoteling's Kiosk handlers: the one place an {OperationResult}
# becomes a response.
#
# WHY A CONCERN rather than the per-controller private renderers the earlier
# slices wrote. hoteling is the first demo whose QUERY half and ACTION half
# refuse with the SAME sentences — the shape guards in {WireArguments} are
# reached from both, because `property_id` is an argument to two queries and one
# action, and `check_in`/`check_out` to two queries and one action. What is
# shared is split exactly as tudu split it: the ANSWER (the refusal and its
# sentence) is {WireArguments}/{OperationResult}, which render nothing and are
# therefore reachable from the Operations too; what is left here is the part
# that genuinely needs a controller, because it calls `render`.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern in
# the operator's own app, which is the whole point of the mixin design — the
# operator owns the structure.
module KioskRefusals
  extend ActiveSupport::Concern

  private

  # Render whatever an Operation (or a shape guard) answered. Success renders the
  # value as-is — the caller already built it in the exact shape the wire
  # publishes — and a refusal becomes the coded envelope below.
  def render_operation(result)
    return render json: result.value if result.ok?

    render_refusal(result)
  end

  # A plain `render json:, status:` naming a code from the wire's closed
  # vocabulary. Naming it is what lets an assistant branch; the status alone
  # would already imply each of these, but writing it keeps the answer explicit.
  # A nil hint is dropped, so a refusal that has nothing to add carries no empty
  # field — which is what keeps these byte-identical to the `Errors::BadRequest`
  # envelopes they replace.
  def render_refusal(result)
    render json: { error: { code: result.code, message: result.message, hint: result.hint }.compact },
           status: result.status
  end
end
