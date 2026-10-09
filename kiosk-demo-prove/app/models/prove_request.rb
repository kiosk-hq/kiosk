# frozen_string_literal: true

# One verification the broker is running. Its unguessable request_id is the
# only credential the human's verification page needs.
class ProveRequest < ApplicationRecord
  self.primary_key = "request_id"

  enum :status, { pending: "pending", confirmed: "confirmed", declined: "declined" }, validate: true

  # Single use, and only within its time to live.
  def confirmable? = pending? && !expired?

  def expired? = expires_at.nil? || Time.current > expires_at
end
