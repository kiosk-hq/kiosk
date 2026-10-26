# frozen_string_literal: true

# A todo on a list. `created_by_agent_id` is the assistant that added it, nil
# when a human did.
class Todo < ApplicationRecord
  belongs_to :list

  # The longest title a list shows; the add_todo schema holds the same limit.
  TITLE_MAX_LENGTH = 200

  validates :title, presence: true, length: { maximum: TITLE_MAX_LENGTH }

  scope :own, -> { where(list_id: Membership.own.select(:list_id)) }
  scope :on, ->(list_id) { where(list_id: list_id).order(:created_at, :id) }
end
