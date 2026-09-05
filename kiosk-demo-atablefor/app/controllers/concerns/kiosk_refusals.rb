# frozen_string_literal: true

# The HTTP half of atablefor's Kiosk handlers: the one place an
# {OperationResult} becomes a response.
#
# WHY A CONCERN rather than the private renderers this conversion replaced.
# atablefor's QUERY half and ACTION half refuse with the SAME sentence —
# "party_size must be >= 1" reaches `availability` and `book_table` alike, because
# a party that cannot be shown a table cannot be booked one either — and the two
# controllers share no superclass but ApplicationController, so before this there
# were two copies of the renderer AND two copies of the sentence, in files that
# never read each other. What is shared is split the way tudu, hoteling, skooti
# and getgrocery split it: the ANSWER (the refusal and its sentence) is
# {WireArguments}/{OperationResult}, which render nothing and are therefore
# reachable from the Operations too; what is left here is the part that genuinely
# needs a controller, because it calls `render`.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# — the operator owns the structure.
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
  # would already imply `bad_request`/`conflict`/`forbidden`, but writing it keeps
  # the answer explicit. A nil hint is dropped — atablefor's refusals carry none —
  # so the envelopes stay byte-identical to the ones the private renderers
  # produced.
  def render_refusal(result)
    render json: { error: { code: result.code, message: result.message, hint: result.hint }.compact },
           status: result.status
  end
end
