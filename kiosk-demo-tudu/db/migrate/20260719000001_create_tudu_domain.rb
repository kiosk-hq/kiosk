# frozen_string_literal: true

# Demo-specific schema: a MULTI-USER COLLABORATIVE todo app.
#
# What is ABSENT is the same not-only-commerce signal philslist ships: no
# mandates, no settlements, no reservations, no money type. tudu takes no money
# at all. What tudu ADDS over philslist is a many-to-many access shape:
#
#   lists        — a todo list, OWNED by one account (account_id).
#   memberships  — the join table: which accounts can reach which lists, and in
#                  what role (owner|member). This is the load-bearing isolation
#                  surface: every list/todo query & action gates on
#                  `EXISTS (SELECT 1 FROM memberships WHERE list_id = :id AND
#                  account_id = kiosk.current_user_id())` — membership-based,
#                  not owner-scoped. "Isolation grows up."
#   todos        — items on a list, attributed to the agent that added them
#                  (created_by_agent_id) — audit as a product feature.
#   invites      — single-use, TTL'd, HASHED collaboration codes. An owner mints
#                  one (`invite`), the plaintext travels human-to-human, and
#                  another account redeems it (`accept_invite`) to gain a `member`
#                  membership. Agent→agent collaboration expressed entirely at the
#                  app layer — the spec stays silent on invites by design.
#
# Under Path C, RLS is OPTIONAL and this demo drops it. App-layer isolation is
# provided instead by the membership EXISTS-check repeated in every query/Action.
class CreateTuduDomain < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    # users.display_name — THE NAME A ROSTER PUBLISHES (K-950).
    #
    # It lives in THIS migration rather than in the shared
    # add_devise_columns_to_users, which three demos hold byte-identical: the
    # column is not part of anybody's login, and tudu is the demo that needs it
    # because tudu is the demo whose verbs name OTHER PEOPLE. atablefor already
    # ships the same column for the same reason (its public reservations board
    # names diners), so this is the fleet's shape and not a new one.
    #
    # NULLABLE on purpose, and the null is a real state rather than a defensive
    # one: every assistant-created principal is a headless row with no human
    # behind it to have chosen anything. {User.public_name} answers that case
    # with an opaque pseudonym derived from the account UUID — see the long note
    # there for why the UUID and never the address.
    add_column :users, :display_name, :string

    # A todo list. account_id is the OWNER (users.id). The rebind hook
    # (config.assistant_claimed) re-parents these to a human on account link.
    create_table :lists, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string     :title, null: false
      t.timestamps
    end

    # The join table — the load-bearing many-to-many access surface. One row per
    # (list, account) pair; role is owner|member. UNIQUE prevents a duplicate
    # membership (and makes accept_invite idempotent at the DB layer).
    create_table :memberships, id: :uuid do |t|
      t.references :list, null: false, foreign_key: true, type: :uuid
      t.references :account, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string     :role, null: false, default: "member"
      t.datetime   :created_at, null: false
    end
    add_index :memberships, %i[list_id account_id], unique: true

    # A todo item on a list. created_by_agent_id records which agent
    # (kiosk.agents.id) added it — attribution in a shared space. Nullable:
    # humans posting through the web surface leave it null.
    create_table :todos, id: :uuid do |t|
      t.references :list, null: false, foreign_key: true, type: :uuid
      t.string     :title, null: false
      t.boolean    :done, null: false, default: false
      t.string     :created_by_agent_id
      t.timestamps
    end
    add_index :todos, :list_id, name: "index_todos_on_list", if_not_exists: true

    # Single-use, TTL'd collaboration codes. Only the SHA-256 digest is stored
    # (code_digest) — the plaintext is returned once from `invite` and travels
    # human-to-human. `accept_invite` looks up by digest, rejects
    # expired/redeemed, and stamps redeemed_by_account_id + redeemed_at.
    create_table :invites, id: :uuid do |t|
      t.references :list, null: false, foreign_key: true, type: :uuid
      t.string     :code_digest, null: false
      t.uuid       :created_by_account_id, null: false
      t.datetime   :expires_at, null: false
      t.uuid       :redeemed_by_account_id
      t.datetime   :redeemed_at
      t.datetime   :created_at, null: false
    end
    add_index :invites, :code_digest, unique: true
  end
end
