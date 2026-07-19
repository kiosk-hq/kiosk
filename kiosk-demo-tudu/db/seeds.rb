# frozen_string_literal: true

# Seeds the tudu collaborative todo app:
#   - two account holders, Alice and Bob, with STABLE UUIDs the assistant
#     scripts use in `Authorization: Bearer agent:u-<uuid>:a-<agent>:r-<role>`
#     headers. Both get Devise credentials so the account-link walkthrough can
#     sign in through the real /users/sign_in form (Alice approves the assistant
#     link there).
#   - NO lists: the flows (demo:collab, demo:link, demo:isolation) create their
#     own lists so each run starts from a known-empty world.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

# Demo-only credentials (development database, reset by every demo:setup).
DEMO_PASSWORD = "tudu-demo-password"

User.find_or_create_by!(id: ALICE_ID) do |u|
  u.email    = "alice@example.com"
  u.password = DEMO_PASSWORD
end
User.find_or_create_by!(id: BOB_ID) do |u|
  u.email    = "bob@example.com"
  u.password = DEMO_PASSWORD
end

puts "Seeded: 2 account holders (#{ALICE_ID} alice@example.com, #{BOB_ID} bob@example.com; " \
     "password #{DEMO_PASSWORD}). No lists — the demo flows create them."
