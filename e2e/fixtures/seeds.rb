# frozen_string_literal: true

# Two synthetic users — Alice and Bob — with stable UUIDs the assistant
# script uses in `Authorization: Bearer agent:u-<uuid>:a-<agent>:r-<role>`
# headers. One salon.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

User.find_or_create_by!(id: ALICE_ID)
User.find_or_create_by!(id: BOB_ID)

Salon.find_or_create_by!(name: "Sweepy on Park")

puts "Seeded: 2 users (#{ALICE_ID}, #{BOB_ID}), 1 salon (#{Salon.first.name})"
