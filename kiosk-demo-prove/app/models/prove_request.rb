# frozen_string_literal: true

# A single verification the broker is running (design §4.1). See the migration
# for the column contract. The request_id is the unguessable capability that
# reaches the human verification page; a confirmer never creates one (only an
# operator does, at intake).
class ProveRequest < ApplicationRecord
  self.primary_key = "request_id"

  STATUSES = %w[pending confirmed declined].freeze

  # A request is confirmable only while pending AND not past its TTL. A
  # confirmed/declined row can never be re-confirmed (single-use); an expired
  # row is un-confirmable (design §4.3).
  def confirmable?
    status == "pending" && !expired?
  end

  def expired?
    expires_at.nil? || Time.current > expires_at
  end
end
