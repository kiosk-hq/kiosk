# frozen_string_literal: true

# A todo on a list. `created_by_agent_id` is the assistant that added it, nil
# when a human did.
class Todo < ApplicationRecord
  belongs_to :list

  validates :title, presence: true

  scope :own, -> { where(list_id: Membership.own.select(:list_id)) }

  # The todos on a list, as `list_todos` publishes them: each deadline on the
  # reader's clock, with that clock named.
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
