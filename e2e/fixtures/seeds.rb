# frozen_string_literal: true

# Two synthetic users — Alice and Bob — with stable UUIDs, and Devise
# credentials for both, because BOTH halves of every ceremony are now real
# (T-066 for the human, T-104 for the agent). The assistant suite no longer
# names a principal in a bearer header: run.sh binds one assistant to each of
# these two humans through the shipped ceremony (register -> link -> claim) and
# hands the suite the tokens the origin issued. claim_flow.rb signs Alice in at
# /users/sign_in and approves an assistant there. One salon.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

# Fixture credentials (a throwaway database this harness drops on every run).
DEMO_PASSWORD = "e2e-demo-password"

User.find_or_create_by!(id: ALICE_ID) do |u|
  u.email    = "alice@example.com"
  u.password = DEMO_PASSWORD
end
User.find_or_create_by!(id: BOB_ID) do |u|
  u.email    = "bob@example.com"
  u.password = DEMO_PASSWORD
end

Salon.find_or_create_by!(name: "Combette on Park")

puts "Seeded: 2 users with Devise credentials (#{ALICE_ID}, #{BOB_ID}), 1 salon (#{Salon.first.name})"
