# frozen_string_literal: true

# A todo list. `account_id` is the account that created it; who may reach it is
# decided by `memberships`.
class List < ApplicationRecord
  belongs_to :account, class_name: "User", foreign_key: :account_id, inverse_of: :lists
  has_many :memberships, dependent: :destroy
  has_many :todos, dependent: :destroy
  has_many :invites, dependent: :destroy

  validates :title, presence: true

  # The current principal's lists, as `my_lists` publishes them and `/lists` shows them.
  def self.reachable_rows
    joins(:memberships).merge(Membership.own)
      .order(created_at: :desc, id: :asc)
      .pluck(:id, :title, Membership.arel_table[:role])
      .map { |id, title, role| { "list_id" => id, "title" => title, "role" => role } }
  end
end
