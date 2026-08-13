# frozen_string_literal: true

# K-698: `confirm_booking` returned a `confirmation_code` to the assistant that
# nothing persisted — a fresh SecureRandom.uuid minted for the response while
# the UPDATE wrote only status and updated_at, against a table that had no such
# column. So the hotel issued a booking reference it kept no record of: a guest
# presenting it at the desk could not be matched.
#
# The published narrative (before-after.md) promises the code as the outcome of
# the confirm step, so it is persisted rather than withdrawn. Nullable — a
# booking only has one once it is confirmed — and UNIQUE, because a reference
# two guests can hold is not a reference (Postgres allows many NULLs under a
# unique index, so the unconfirmed rows are unaffected).
class AddConfirmationCodeToBookings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :bookings, :confirmation_code, :string
    add_index  :bookings, :confirmation_code, unique: true
  end
end
