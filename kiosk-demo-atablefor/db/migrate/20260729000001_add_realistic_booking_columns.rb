# frozen_string_literal: true

# Realistic-content columns for the atablefor redesign (K-435 demo redesign):
#   - users.display_name  — the diner's public name shown on the read-only
#     reservations board (so the board reads "party 2 · Terrace 2 · 20:00 ·
#     Diego", not a raw email). NULLable: assistant accounts have no name.
#   - restaurants.neighborhood — a realistic locality ("Alfama") surfaced on
#     the home page.
#   - table_slots.deposit_eur — an OPTIONAL no-show hold shown in EUR on prime
#     tables. It is DISPLAY-ONLY: atablefor advertises no `pay` verb, so this is
#     a figure the diner settles at the restaurant, never money on the wire.
class AddRealisticBookingColumns < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :users,       :display_name, :string
    add_column :restaurants, :neighborhood, :string
    # EUR whole-euro no-show hold; null/0 = no deposit on that table.
    add_column :table_slots, :deposit_eur,  :integer, null: false, default: 0
  end
end
