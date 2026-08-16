# frozen_string_literal: true

# A classifieds ad. The load-bearing detail: `price_text` is a plain NULLABLE
# STRING ("€300", "Free", or NULL), NOT a money type — the board never
# transacts on it. A commerce reviewer looking for a hidden PSP finds only a
# display string. `owner_id` is the account that posted the ad; `edit`/`close`
# are scoped to `owner_id = kiosk.current_user_id()` (app-layer isolation).
class Listing < ApplicationRecord
  STATUSES = %w[open closed].freeze

  belongs_to :owner, class_name: "User", foreign_key: :owner_id, inverse_of: :listings
  belongs_to :category

  validates :title, presence: true
  validates :body, presence: true
  validates :status, inclusion: { in: STATUSES }

  # ── THE isolation predicate ────────────────────────────────────────────────
  # When philslist's handlers stopped writing SQL (K-654), this is the one
  # fragment that deliberately did NOT become a Ruby comparison. Why:
  #
  # `kiosk.current_user_id()` is a STABLE Postgres function that reads the
  # transaction-local GUC `app.current_user_id`. kiosk-server's SessionContext
  # sets that GUC with `SET LOCAL`, from the identity the wire resolved, inside
  # the very transaction the handler runs in — so the principal is never a value
  # this process hands to the query. The database reads it, from state no request
  # argument can reach, and it evaporates at COMMIT.
  #
  # `where(owner_id: <a ruby value>)` would be just as unforgeable *here* (the
  # only value available is the same wire-resolved identity). What it would cost
  # is the part that generalises: the predicate would stop being expressed in the
  # terms an RLS policy is written in — spec §7 makes DB-enforced identity
  # scoping a MUST and `kiosk.current_user_id()` is the seam where the app-layer
  # predicate and the optional DB-layer policy are literally the same expression
  # — and a demo is the reference other operators copy.
  #
  # `Arel.sql` over a frozen literal rather than an interpolated string: there is
  # no caller-controlled value anywhere in this fragment. That is what makes it
  # exempt from the no-raw-SQL rule rather than an exception to it.
  scope :owned_by_current_principal, lambda {
    where(arel_table[:owner_id].eq(Arel.sql("kiosk.current_user_id()")))
  }
end
