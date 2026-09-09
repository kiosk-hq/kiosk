# frozen_string_literal: true

# ── A TABLE IS SERVED WHERE THE TABLE IS, AND NOW THAT IS RECORDED ──────────
#
# atablefor is an AGGREGATOR: one origin, many restaurants. It answered all of
# them from one zone constant configured on the origin, which is right for as
# long as every restaurant is in one city and stops being right the day this
# aggregator lists one that is not. The rule is that the zone belongs to the
# thing being SERVED -- this restaurant, this table -- because one operator may
# list places in many time zones and locations.
#
# WHY A COLUMN AND NOT A DERIVATION. `restaurants.neighborhood` is the only
# location string this demo stores, it is nullable, and «Alfama» is a Lisbon
# district only to someone who already knows that. Deriving a clock from it is
# exactly the inference the rule forbids: an answer nobody declared and nobody
# can falsify from the client side.
#
# WHY THE DEFAULT STAYS ON THE COLUMN. It is the ORIGIN's default zone, and its
# job is to FILL this column rather than to answer a request: every existing row
# backfills to it, and a restaurant added without a zone is declared to be in
# Lisbon rather than being in no zone at all. `NOT NULL` is what stops the
# "resource with no zone" case from ever arising.
class AddTimezoneToRestaurants < ActiveRecord::Migration[8.1]
  def change
    add_column :restaurants, :timezone, :string, null: false, default: "Europe/Lisbon"
  end
end
