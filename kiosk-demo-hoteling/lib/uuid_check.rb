# frozen_string_literal: true

# Shape check for the uuids that arrive from the wire (K-581/K-582).
#
# hoteling's SQL builds `'<value>'::uuid` casts from agent-supplied ids — the
# `booking_id` arg of confirm_booking, and the `{"booking_id":…}` entry inside a
# signed cart mandate's line_items that ValidatingBookingProvider prices at
# capture. Postgres rejects a malformed literal with
# `PG::InvalidTextRepresentation` (SQLSTATE 22P02), which is not a
# `Kiosk::Server::Errors::Base` and so escapes the wire controller's rescue as a
# raw HTTP 500: a CLIENT mistake reported as a server fault, and on the pay path
# a 500 is the worst possible answer because an assistant cannot tell it from
# "the charge may have happened". Callers validate the shape first and raise a
# typed 4xx instead.
#
# Format only — that an id is a well-formed uuid says nothing about whether the
# row exists or belongs to the caller; the ownership/state SQL still decides that.
#
# A byte-identical copy of this module lives in every demo that casts a
# wire-supplied id (getgrocery, skooti, atablefor, tudu, philslist). Each demo
# is a standalone Rails app with its own Gemfile, so the alternative to a copy is
# publishing the guard in a shipped gem — a public-API decision, not a fix-wave
# one. Same arrangement as lib/pow_difficulty.rb and lib/equihash_register.rb.
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
