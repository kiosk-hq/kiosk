# frozen_string_literal: true

# ── A PROPERTY'S CLOCK IS THE PROPERTY'S, AND NOW IT IS RECORDED ─────────────
#
# hoteling sold a hundred room-nights off ONE zone constant configured on the
# origin. The answer was right, because all hundred properties are in Istanbul;
# the SOURCE was wrong, and it stops being right the day this operator opens a
# hotel anywhere else. The rule is that the zone belongs to the thing being
# SERVED, because one operator may run stores in many time zones and locations.
#
# WHY A COLUMN AND NOT A DERIVATION. `properties.city` is NOT NULL on all 100
# rows and «Istanbul» maps to `Europe/Istanbul` without much imagination — which
# is exactly the inference the rule forbids. A city string is a label a human
# typed; a zone is an operational fact, and guessing one from the other produces
# an answer nobody declared and nobody can falsify from the client side.
#
# WHY THE DEFAULT STAYS ON THE COLUMN. It is the ORIGIN's default zone, and its
# job is to FILL this column rather than to answer a request: every existing row
# backfills to it, and a property created without a zone is declared to be in
# Istanbul rather than being in no zone at all. `NOT NULL` is what stops the
# "resource with no zone" case from ever arising.
class AddTimezoneToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :timezone, :string, null: false, default: "Europe/Istanbul"
  end
end
