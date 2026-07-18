# frozen_string_literal: true

# Two synthetic account holders — Alice and Bob — with stable UUIDs the
# assistant script uses in `Authorization: Bearer agent:u-<uuid>:a-<agent>:r-<role>`
# headers. Both get Devise credentials so the account-binding walkthrough can
# sign in through the real /users/sign_in form (Alice approves the assistant
# link there). One salon.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

# Demo-only credentials (development database, reset by every demo:setup).
DEMO_PASSWORD = "combette-demo-password"

User.find_or_create_by!(id: ALICE_ID) do |u|
  u.email    = "alice@example.com"
  u.password = DEMO_PASSWORD
end
User.find_or_create_by!(id: BOB_ID) do |u|
  u.email    = "bob@example.com"
  u.password = DEMO_PASSWORD
end

Salon.find_or_create_by!(name: "Combette on Park")

puts "Seeded: 2 account holders (#{ALICE_ID}, #{BOB_ID}; sign-in alice@example.com / #{DEMO_PASSWORD}), 1 salon (#{Salon.first.name})"
