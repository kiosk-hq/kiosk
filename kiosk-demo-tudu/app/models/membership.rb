# frozen_string_literal: true

# The join row that grants an account access to a list. This is tudu's
# many-to-many "isolation grows up" surface: every list/todo query & action
# checks a membership EXISTS for the GUC principal, and `remove_member` DELETEs
# one to cut access instantly. `role` is owner|member — the owner (there is at
# least one) holds invite/remove authority.
class Membership < ApplicationRecord
  ROLES = %w[owner member].freeze

  belongs_to :list
  belongs_to :account, class_name: "User", foreign_key: :account_id, inverse_of: :memberships

  validates :role, inclusion: { in: ROLES }
  validates :account_id, uniqueness: { scope: :list_id }
end
