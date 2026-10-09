# frozen_string_literal: true

# Two housemates who sign in with a password, and the household list they share.
# Assistants register themselves on the wire. A roster shows the display name,
# never the address.

password = "tudu-demo-password"
alice, bob = [
  { id: "00000000-0000-0000-0000-000000000001", email: "alice@example.com", display_name: "Alice" },
  { id: "00000000-0000-0000-0000-000000000002", email: "bob@example.com",   display_name: "Bob" },
].map do |housemate|
  User.find_or_initialize_by(id: housemate[:id]).tap do |user|
    user.assign_attributes(housemate)
    user.password = password unless user.valid_password?(password)
    user.save!
  end
end

flat = List.find_or_create_by!(account: alice, title: "Flat 3B")
Membership.find_or_create_by!(list: flat, account: alice) { _1.role = "owner" }
Membership.find_or_create_by!(list: flat, account: bob)   { _1.role = "member" }
["Pay the internet bill", "Buy dish soap"].each { Todo.find_or_create_by!(list: flat, title: _1) }

Rails.logger.info "Seeded: #{alice.display_name} and #{bob.display_name}, sharing #{flat.title} with #{flat.todos.count} todos"
