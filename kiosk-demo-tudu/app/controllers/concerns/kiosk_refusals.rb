# frozen_string_literal: true

# The HTTP half of tudu's Kiosk handlers: the one place an {OperationResult}
# becomes a response.
#
# WHY A CONCERN, in a repo whose three earliest T-057 slices duplicated a
# four-line `render_bad_request` rather than invent one. tudu was the fourth demo
# whose QUERY half refuses as well as its action half, and the first where the two
# halves refuse the SAME WAY. What is shared is split in two: the ANSWER (shape
# check, membership predicate, and the sentence each refusal carries) is
# {ListAccess}, which renders nothing and is therefore reachable from the
# Operations and the human web controllers as well; what is left here is the part
# that genuinely needs a controller, because it calls `render`.
#
# WHY IT IS ITS OWN FILE (T-083). These two renderers used to live inside
# {KioskMembershipGate} — the same code as the other six demos' `KioskRefusals`,
# under a name only tudu used, at a path `bin/check-demo-copies` could not match
# against its siblings. The lockstep rule pairs copies by relative path, so tudu's
# were compared to nothing and were free to drift from the fleet's while every
# check stayed green. Splitting the file is what puts all seven under the gate;
# the membership guard stays next door, because it is tudu's alone.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# (K-495: the operator owns the structure). A gem-level
# `render_kiosk_error(code:, message:)` would cover `render_refusal` below and
# nothing else; it is not proposed here (K-792 carries that question).
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
