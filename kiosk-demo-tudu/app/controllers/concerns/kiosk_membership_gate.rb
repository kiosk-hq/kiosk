# frozen_string_literal: true

# The membership gate both Kiosk handler controllers open with, plus the two
# refusal renderers they share.
#
# WHY A CONCERN, in a repo whose three earlier T-057 slices duplicated a
# four-line `render_bad_request` rather than invent one. tudu is the fourth demo
# whose QUERY half refuses as well as its action half, and it is the first where
# the two halves refuse the SAME WAY: the gate below — shape check, then the
# membership predicate, then one of two 403s — is ~25 lines that
# `Kiosk::HouseholdController` and `Kiosk::TodoListsController` would otherwise
# carry verbatim, and a message that drifted in one copy would be a wire
# difference nobody could see. Four lines twice is a copy; twenty-five lines
# twice is a maintenance liability, so this is where the line is drawn.
#
# It is deliberately the HTTP half only. The access DECISION is
# `Membership.reachable?`, a model method with no request in it — see the long
# note there for why the split runs where it does. What is left here genuinely
# needs a controller: it calls `render`.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# (K-495: the operator owns the structure). A gem-level
# `render_kiosk_error(code:, message:)` would cover the two renderers below and
# nothing else; it is not proposed here.
module KioskMembershipGate
  extend ActiveSupport::Concern

  private

  # Membership guard: renders the refusal and answers false when the caller may
  # not reach `list_id`, true when it may. Call it as a guard clause —
  #
  #   return unless kiosk_membership_gate(params[:list_id])
  #
  # — so the refusal is already rendered when the action returns.
  #
  # Forbidden (not NotFound) so cross-list probing can't enumerate which ids
  # exist — the philslist pattern, adapted to membership-based access.
  # `require_owner` tightens it to role='owner' (invite/remove_member authority).
  #
  # K-581/K-582: `list_id` arrives from the wire and is cast `::uuid` inside the
  # predicate — and because every membership-gated verb (list_todos,
  # list_members, add_todo, invite, remove_member) opens with this guard, this
  # ONE check covers all of them. A malformed value made Postgres raise
  # InvalidTextRepresentation, which is not a Kiosk error and so surfaced as a
  # raw 500 (leaking "invalid input syntax for type uuid") for what is plainly a
  # client mistake. Shape first, then the membership predicate — a well-formed
  # but foreign id still gets the 403, so the shape check never softens the
  # access answer.
  def kiosk_membership_gate(list_id, require_owner: false)
    unless UuidCheck.valid?(list_id)
      render_bad_request(
        "list_id #{list_id.to_s.inspect} is not a uuid",
        hint: "Pass a `list_id` from my_lists (or the one create_list returned), verbatim.",
      )
      return false
    end

    return true if Membership.reachable?(list_id, require_owner: require_owner)

    render_forbidden(
      require_owner ? "list not owned by the authenticated principal" \
                    : "list not accessible by the authenticated principal",
      hint: require_owner ? "Only the list owner may do this." \
                          : "You may only reach lists you are a member of.",
    )
    false
  end

  # The two refusals below are plain `render json:, status:` naming a code from
  # the wire's closed vocabulary. Naming it is what lets an assistant branch;
  # the status alone would already imply each of these, but writing it keeps the
  # answer explicit. A nil hint is dropped, so a refusal that has nothing to add
  # carries no empty field.
  def render_bad_request(message, hint: nil)
    render json: { error: { code: "bad_request", message: message, hint: hint }.compact },
           status: :bad_request
  end

  def render_forbidden(message, hint: nil)
    render json: { error: { code: "forbidden", message: message, hint: hint }.compact },
           status: :forbidden
  end
end
