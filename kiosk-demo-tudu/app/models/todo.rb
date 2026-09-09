# frozen_string_literal: true

# A todo item on a list. `created_by_agent_id` records which agent
# (kiosk.agents.id) added it — attribution in a shared space ("who added this? —
# Bob's assistant"). Nullable: a human adding a todo through the web surface
# leaves it null. Access is membership-gated through the parent list.
class Todo < ApplicationRecord
  belongs_to :list

  validates :title, presence: true

  # ── THE PROJECTION BOTH OF tudu's DOORS READ ───────────────────────────────
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
  # AND IT IS RENDERED PER READER, which is the one thing on this projection
  # that is not a plain column read. `due_at` is stored as an absolute instant
  # because a shared list has TWO readers and no single wall-clock string is
  # correct for both; the wall clock comes out of {ReaderClock}, on the zone
  # THIS request declared, and `timezone` says which one that was. The web
  # page reaches this method too and declares none, so it renders on the
  # household's own clock — the declared fallback, not an accident.
  #
  # @return [Array<Hash>]
  def self.rows_on(list_id)
    zone = ReaderClock.zone
    where(list_id: list_id).order(:created_at, :id)
      .pluck(:id, :title, :done, :created_by_agent_id, :due_at)
      .map { |id, title, done, agent_id, due_at|
        { "todo_id" => id, "title" => title, "done" => done, "created_by_agent_id" => agent_id,
          "due_at" => ReaderClock.publish(due_at, zone),
          "due_label" => ReaderClock.label(due_at, zone),
          "timezone" => zone.name }
      }
  end
end
