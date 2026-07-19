# frozen_string_literal: true

# Demo-specific schema: a NON-COMMERCE classifieds board.
#
# The point of this demo is what is ABSENT: no mandates, no settlements, no
# reservations, no money type. `listings.price_text` is a plain NULLABLE string
# (display metadata the board never transacts on) — the strongest possible
# signal that this surface has no payment semantics.
#
# Under Path C, RLS is OPTIONAL and this demo drops it. App-layer isolation is
# provided instead:
#   - `post_listing`  Action scopes INSERT owner_id to kiosk.current_user_id()
#   - `edit_listing` / `close_listing` UPDATE … WHERE owner_id = kiosk.current_user_id()
#   - `my_listings`   named Query filters WHERE owner_id = kiosk.current_user_id()
#   - `browse_listings` named Query is open-read (cross-owner, no per-user filter)
class CreateCategoriesAndListings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :categories do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :categories, :slug, unique: true

    create_table :listings, id: :uuid do |t|
      # owner_id → users.id (the account principal, ADR-0010). The load-bearing
      # isolation predicate: edit/close are scoped to owner_id.
      t.references :owner, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :category, null: false, foreign_key: true
      t.string     :title, null: false
      t.text       :body,  null: false
      # price_text: NULLABLE display STRING, deliberately NOT a money type.
      t.string     :price_text
      t.string     :status, null: false, default: "open"
      # Attribution: which agent (kiosk.agents.id) created the listing, if any.
      # Nullable — humans posting through the web surface leave it null.
      t.string     :created_by_agent_id
      t.timestamps
    end
    add_index :listings, :status
    add_index :listings, %i[category_id status]
  end
end
