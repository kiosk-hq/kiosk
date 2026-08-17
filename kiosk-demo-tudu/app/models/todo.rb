# frozen_string_literal: true

# A todo item on a list. `created_by_agent_id` records which agent
# (kiosk.agents.id) added it — attribution in a shared space ("who added this? —
# Bob's assistant"). Nullable: a human adding a todo through the web surface
# leaves it null. Access is membership-gated through the parent list.
class Todo < ApplicationRecord
  belongs_to :list

  validates :title, presence: true

  # ── THE PROJECTION BOTH OF tudu's DOORS READ (T-082) ───────────────────────
  # The todos on one list, in the shape `list_todos` publishes: one string-keyed
  # row each, with the attribution the demo exists to show.
  #
  # ACCESS IS NOT ASKED HERE, and that is the load-bearing part. `list_id` is
  # already-authorised by the time this runs — every caller consults
  # {ListAccess.check} (which asks {Membership.reachable?}) first, and answers 400
  # for a malformed id and 403 for a foreign one before any row is read. Folding
  # the membership predicate in here as well would put the same test in two places
  # and let a future caller believe this method is the guard. It is not; it is the
  # projection the guard protects. See {List.reachable_rows} for why the shape
  # lives on the model at all and why the strings are not cosmetic.
  #
  # @return [Array<Hash>]
  def self.rows_on(list_id)
    where(list_id: list_id).order(:created_at, :id)
      .pluck(:id, :title, :done, :created_by_agent_id)
      .map { |id, title, done, agent_id|
        { "todo_id" => id, "title" => title, "done" => done, "created_by_agent_id" => agent_id }
      }
  end
end
