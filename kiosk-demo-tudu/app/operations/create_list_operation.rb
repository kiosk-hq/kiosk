# frozen_string_literal: true

# A new list, owned by the principal that creates it.
class CreateListOperation
  def self.call(principal_id:, title:)
    list = List.create!(account_id: principal_id, title: title,
                        memberships: [Membership.new(account_id: principal_id, role: :owner)])
    { list_id: list.id }
  end
end
