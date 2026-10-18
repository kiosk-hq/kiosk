# frozen_string_literal: true

# A todo list. `account_id` is the account that created it; who may reach it is
# decided by `memberships`.
class List < ApplicationRecord
  belongs_to :account, class_name: 'User', inverse_of: :lists
  has_many :memberships, dependent: :destroy
  has_many :todos, dependent: :destroy
  has_many :invites, dependent: :destroy

  validates :title, presence: true

  def owner = memberships.find(&:owner?).account

  # Oldest first, from the loaded todos.
  def tasks = todos.sort_by { [it.created_at, it.id] }

  # The signed-in member's lists, newest first, each carrying the member's `role` on it.
  scope :reachable, lambda {
    joins(:memberships).merge(Membership.own)
                       .select(arel_table[Arel.star], Membership.arel_table[:role])
                       .order(created_at: :desc, id: :asc)
  }
end
