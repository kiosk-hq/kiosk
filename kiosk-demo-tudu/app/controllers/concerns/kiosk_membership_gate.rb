# frozen_string_literal: true

# THE MEMBERSHIP GUARD tudu's QUERY controller opens with — the rendering half
# of {ListAccess}, and the only thing in this file that is tudu's alone.
#
# WHY IT IS SEPARATE FROM {KioskRefusals} (T-083). Until now this file also held
# `render_operation`/`render_refusal` — code the other six demos ship verbatim as
# `KioskRefusals`, but under a name only tudu used. `bin/check-demo-copies` pairs
# copies by relative PATH, so tudu's pair was compared to nothing and was free to
# drift from the fleet's while every check stayed green. The renderers moved to
# `kiosk_refusals.rb` (where the gate now finds them, as a Concern dependency),
# and what is left here is the one guard the fleet does not share, because no
# other demo has membership-based access.
#
# WHY THE GUARD IS A CONCERN AT ALL. tudu was the first demo where both halves of
# the wire refuse the SAME WAY, and what is shared is split in two: the ANSWER
# (shape check, membership predicate, and the sentence each refusal carries) is
# {ListAccess}, which renders nothing and is therefore reachable from the
# Operations and the human web controllers as well; what is left here is the part
# that genuinely needs a controller, because it calls `render`.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# (K-495: the operator owns the structure).
module KioskMembershipGate
  extend ActiveSupport::Concern

  # The renderer this guard needs. An ActiveSupport::Concern dependency, so a
  # controller that includes the gate gets `render_refusal` without having to
  # know the gate uses it.
  include KioskRefusals

  private

  # Membership guard for the two QUERIES (list_todos, list_members), which have
  # no Operation to hold their precondition. Call it as a guard clause —
  #
  #   return unless kiosk_membership_gate(params[:list_id])
  #
  # — so the refusal is already rendered when the action returns. `require_owner`
  # tightens it to role='owner'; no query needs that today, and the parameter
  # stays because {ListAccess} is the shared definition, not this wrapper.
  #
  # The human web UI does NOT come through here: `/lists/:id` consults
  # {ListAccess.check} itself and presents the same refusal as a flash rather than
  # a rendered body (T-082). Same question, same answer, two presentations —
  # which is exactly why the question does not live in a renderer.
  def kiosk_membership_gate(list_id, require_owner: false)
    refusal = ListAccess.check(list_id, require_owner: require_owner)
    return true if refusal.nil?

    render_refusal(refusal)
    false
  end
end
