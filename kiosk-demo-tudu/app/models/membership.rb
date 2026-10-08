# frozen_string_literal: true

# An account's access to a list. An owner may invite and remove members.
class Membership < ApplicationRecord
  enum :role, { owner: "owner", member: "member" }, validate: true

  belongs_to :list
  belongs_to :account, class_name: "User", foreign_key: :account_id, inverse_of: :memberships

  validates :account_id, uniqueness: { scope: :list_id }

  scope :own, -> { where(account_id: Kiosk.current_user_id) }

  def self.account_ids_on(list_id) = where(list_id: list_id).pluck(:account_id)

  # Outside a request, where `own` has no principal: the event stream asks this.
  def self.readable_by?(list_id, account_id) = where(list_id: list_id, account_id: account_id).exists?

  # Who is on a list, as `list_members` publishes it. Never an email address.
  def self.rows_on(list_id)
    where(list_id: list_id).joins(:account)
      .order(role: :desc, created_at: :asc)
      .pluck(:account_id, User.arel_table[:display_name], :role)
      .map { |account_id, display_name, role|
        { "account_id"   => account_id,
          "display_name" => User.public_name(display_name, account_id),
          "role"         => role }
      }
  end
end
