# frozen_string_literal: true

# Seeds the tudu collaborative todo app:
#   - two account holders, Alice and Bob, with STABLE UUIDs: the rake tasks
#     pass Alice's as HOLDER_ID and the public housemate view pins Bob's, so
#     both survive a reset. They are NOT credentials — an assistant
#     authenticates with the kiosk-pop JWT the engine mints at
#     /kiosk/auth/register, /auth/login or the binding ceremony. Both holders
#     get Devise credentials so the account-link walkthrough can sign in
#     through the real /users/sign_in form (Alice approves the assistant link
#     there).
#   - a SEEDED HOUSEHOLD so collaboration has a concrete starting point and the
#     public housemate view (/shared) is never empty: a shared list "Flat 3B"
#     owned by Alice with a couple of tasks, and Bob seeded as a MEMBER (the
#     "housemate"). This is the row the housemate view renders — when an
#     assistant later creates + shares a list with Bob, the new shared list
#     shows up alongside it, so a viewer SEES the collaboration land.
#
# The wire flows (demo:collab, demo:link, demo:isolation) create their OWN lists
# named "Hike" and assert on those, so the seeded "Flat 3B" household never
# collides with a flow's assertions.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

# Demo-only credentials (development database, reset by every demo:setup).
DEMO_PASSWORD = "tudu-demo-password"

# display_name is what the ROSTER publishes (K-950). `list_members` used to
# publish `users.email`, so every housemate learned every other housemate's
# login address; it publishes this column instead, and an account that has
# chosen no name — every assistant-created principal — gets the opaque
# `member-<hex>` {User.public_name} derives from its UUID. Seeded here so the
# demo's own household reads the way a household should ("Alice", "Bob") rather
# than as two hashes: a name the reader recognises is the point of the verb.
alice = User.find_or_create_by!(id: ALICE_ID) do |u|
  u.email        = "alice@example.com"
  u.display_name = "Alice"
  u.password     = DEMO_PASSWORD
end
bob = User.find_or_create_by!(id: BOB_ID) do |u|
  u.email        = "bob@example.com"
  u.display_name = "Bob"
  u.password     = DEMO_PASSWORD
end

# ── The seeded household: a shared list Alice owns and Bob is a member of ─────
# "Flat 3B" is the housemates' shared list. Alice created and owns it; Bob (the
# housemate whose view the /shared page renders) is a member — collaboration
# already landed once, so the housemate view has something concrete to show
# before any wire call runs. Idempotent: find_or_create keyed on (account, title)
# so re-seeding is a no-op.
flat = List.find_or_create_by!(account: alice, title: "Flat 3B") do |l|
  l.created_at = Time.current
  l.updated_at = Time.current
end

# Alice is the owner; Bob is a member (the shared-with housemate). One row each,
# idempotent on the UNIQUE(list_id, account_id) index.
Membership.find_or_create_by!(list: flat, account: alice) { |m| m.role = "owner"  }
Membership.find_or_create_by!(list: flat, account: bob)   { |m| m.role = "member" }

# A couple of starter tasks on the shared list (created via the web surface, so
# no agent attribution — created_by_agent_id stays null). Idempotent on title.
["Pay the internet bill", "Buy dish soap"].each do |task|
  Todo.find_or_create_by!(list: flat, title: task) do |t|
    t.done = false
  end
end

puts "Seeded: 2 account holders (#{ALICE_ID} alice@example.com as \"#{alice.display_name}\", " \
     "#{BOB_ID} bob@example.com as \"#{bob.display_name}\"; password #{DEMO_PASSWORD}); household " \
     "\"#{flat.title}\" owned by alice, shared with bob (housemate) — #{flat.todos.count} tasks. " \
     "The wire publishes the display names, never the addresses. The wire flows create their own " \
     "\"Hike\" lists."
