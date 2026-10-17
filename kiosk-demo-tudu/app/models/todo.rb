# frozen_string_literal: true

# A todo on a list. `created_by_agent_id` is the assistant that added it, nil
# when a human did.
class Todo < ApplicationRecord
  belongs_to :list

  validates :title, presence: true

  scope :own, -> { where(list_id: Membership.own.select(:list_id)) }
  scope :on, ->(list_id) { where(list_id: list_id).order(:created_at, :id) }
end
