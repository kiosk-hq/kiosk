# frozen_string_literal: true

# The refusal a caller gets for a list it may not reach. Forbidden either way,
# so a stranger cannot tell which list ids exist.
module ListAccess
  module_function

  def member!(list_id)
    return if Membership.own.exists?(list_id: list_id)

    raise Kiosk::Server::Errors::Forbidden.new("list not accessible by the authenticated principal",
                                               hint: "You may only reach lists you are a member of.")
  end

  def owner!(list_id)
    return if Membership.own.owner.exists?(list_id: list_id)

    raise Kiosk::Server::Errors::Forbidden.new("list not owned by the authenticated principal",
                                               hint: "Only the list owner may do this.")
  end
end
