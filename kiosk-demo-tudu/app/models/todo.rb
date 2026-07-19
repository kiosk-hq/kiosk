# frozen_string_literal: true

# A todo item on a list. `created_by_agent_id` records which agent
# (kiosk.agents.id) added it — attribution in a shared space ("who added this? —
# Bob's assistant"). Nullable: a human adding a todo through the web surface
# leaves it null. Access is membership-gated through the parent list.
class Todo < ApplicationRecord
  belongs_to :list

  validates :title, presence: true
end
