# frozen_string_literal: true

# Shape check for the order uuids that arrive from the wire (K-579).
#
# getgrocery's SQL builds `'<value>'::uuid` casts from agent-supplied ids — the
# `order_id` in create_order / reschedule_delivery args, and the `{"order_id":…}`
# entry inside a signed cart mandate's line_items. Postgres rejects a malformed
# literal with `PG::InvalidTextRepresentation` (SQLSTATE 22P02), which is not a
# `Kiosk::Server::Errors::Base` and so escapes the wire controller's rescue as a
# raw HTTP 500: a CLIENT mistake reported as a server fault, and on the pay path
# a 500 is the worst possible answer because an assistant cannot tell it from
# "the charge may have happened". Callers validate the shape first and raise a
# typed 4xx instead.
#
# Format only — that an id is a well-formed uuid says nothing about whether the
# row exists or belongs to the caller; the ownership/state SQL still decides that.
module UuidCheck
  # Canonical 8-4-4-4-12 hex form, the only shape Postgres' `uuid` type is fed
  # here (gen_random_uuid() output, echoed back by the agent). Postgres itself
  # would also accept a few non-canonical spellings (brace-wrapped,
  # un-hyphenated); we deliberately require the canonical form the operator
  # hands out, so the rejection can name exactly what to send back.
  PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # @param value [Object] the candidate id (usually a String off the wire)
  # @return [Boolean] true iff `value` is a canonical uuid literal
  def self.valid?(value)
    PATTERN.match?(value.to_s)
  end
end
