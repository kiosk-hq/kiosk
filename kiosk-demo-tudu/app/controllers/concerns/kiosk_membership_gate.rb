# frozen_string_literal: true

# The HTTP half of tudu's Kiosk handlers: the membership guard the QUERY
# controller opens with, and the one place an {OperationResult} becomes a
# response.
#
# WHY A CONCERN, in a repo whose three earlier T-057 slices duplicated a
# four-line `render_bad_request` rather than invent one. tudu is the fourth demo
# whose QUERY half refuses as well as its action half, and the first where the
# two halves refuse the SAME WAY. What is shared is now split in two: the
# ANSWER (shape check, membership predicate, and the sentence each refusal
# carries) is {ListAccess}, which renders nothing and is therefore reachable
# from the Operations and the human web controllers as well; what is left here
# is the part that genuinely needs a controller, because it calls `render`.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# (K-495: the operator owns the structure). A gem-level
# `render_kiosk_error(code:, message:)` would cover `render_refusal` below and
# nothing else; it is not proposed here.
module KioskMembershipGate
  extend ActiveSupport::Concern

  private

  # Render whatever an Operation answered. Success renders the value as-is —
  # the Operation already built it string-keyed in the exact shape the wire
  # publishes — and a refusal becomes the coded envelope below.
  def render_operation(result)
    return render json: result.value if result.ok?

    render_refusal(result)
  end

  # Membership guard for the two QUERIES (list_todos, list_members), which have
  # no Operation to hold their precondition. Call it as a guard clause —
  #
  #   return unless kiosk_membership_gate(params[:list_id])
  #
  # — so the refusal is already rendered when the action returns. `require_owner`
  # tightens it to role='owner'; no query needs that today, and the parameter
  # stays because {ListAccess} is the shared definition, not this wrapper.
  def kiosk_membership_gate(list_id, require_owner: false)
    refusal = ListAccess.check(list_id, require_owner: require_owner)
    return true if refusal.nil?

    render_refusal(refusal)
    false
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
