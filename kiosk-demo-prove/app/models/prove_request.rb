# frozen_string_literal: true

# A single verification the broker is running. See the migration
# for the column contract. The request_id is the unguessable capability that
# reaches the human verification page; a confirmer never creates one (only an
# operator does, at intake).
class ProveRequest < ApplicationRecord
  self.primary_key = "request_id"

  STATUSES = %w[pending confirmed declined].freeze
  # The column is a bare varchar with no CHECK constraint (db/structure.sql), so
  # until this validation the constant was the ONLY statement of the invariant
  # and nothing read it — a typo'd status wrote fine and `confirmable?` then
  # answered false for a row that was, in every other sense, pending (K-712g).
  validates :status, inclusion: { in: STATUSES }

  # A request is confirmable only while pending AND not past its TTL. A
  # confirmed/declined row can never be re-confirmed (single-use); an expired
  # row is un-confirmable.
  def confirmable?
    status == "pending" && !expired?
  end

  def expired?
    expires_at.nil? || Time.current > expires_at
  end
end
