# frozen_string_literal: true

# An account's access to a list. An owner may invite and remove members.
class Membership < ApplicationRecord
  enum :role, { owner: 'owner', member: 'member' }, validate: true

  belongs_to :list
  belongs_to :account, class_name: 'User', inverse_of: :memberships

  validates :account_id, uniqueness: { scope: :list_id }

  scope :own, -> { where(account_id: Kiosk.current_user_id) }

  def self.account_ids_on(list_id) = where(list_id: list_id).pluck(:account_id)

  # Outside a request, where `own` has no signed-in member: the event stream asks this.
  def self.readable_by?(list_id, account_id) = exists?(list_id: list_id, account_id: account_id)

  # Every list one account is on, newest first, with its members and tasks.
  scope :board_of, lambda { |account_id|
    where(account_id:).joins(:list).includes(list: [:todos, { memberships: :account }])
                      .order(List.arel_table[:created_at].desc, :list_id)
  }

  # Who is on a list, owners first.
  scope :roster, ->(list_id) { where(list_id: list_id).includes(:account).in_order_of(:role, %w[owner member]).order(:created_at) }

  # The name other members see; never an email address.
  def display_name = account.public_name
end
