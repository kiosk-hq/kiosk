# frozen_string_literal: true

# A todo list. `account_id` is the OWNER account (users.id) — but access is NOT
# owner-scoped: a list is reachable by every account with a `memberships` row for
# it. The owner is just the member whose role is 'owner' (invite/remove_member
# authority). The load-bearing isolation predicate is `Membership.reachable?`:
# `EXISTS (SELECT 1 FROM memberships WHERE list_id = :id AND account_id =
# kiosk.current_user_id())`, called by every list-scoped verb through
# KioskMembershipGate.
class List < ApplicationRecord
  belongs_to :account, class_name: "User", foreign_key: :account_id, inverse_of: :lists
  has_many :memberships, dependent: :destroy
  has_many :todos, dependent: :destroy
  has_many :invites, dependent: :destroy

  validates :title, presence: true
end
