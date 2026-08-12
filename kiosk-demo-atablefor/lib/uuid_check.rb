# frozen_string_literal: true

# Shape check for the uuids that arrive from the wire (K-581/K-582).
#
# atablefor's SQL builds `'<value>'::uuid` casts from agent-supplied ids — the
# `booking_id` arg of cancel_booking. Postgres rejects a malformed literal with
# `PG::InvalidTextRepresentation` (SQLSTATE 22P02), which is not a
# `Kiosk::Server::Errors::Base` and so escapes the wire controller's rescue as a
# raw HTTP 500: a CLIENT mistake reported as a server fault, and one that leaks
# SQL internals ("invalid input syntax for type uuid") to the wire. Callers
# validate the shape first and raise a typed 4xx instead.
#
# Format only — that an id is a well-formed uuid says nothing about whether the
# row exists or belongs to the caller; the ownership/state SQL still decides that.
#
# A copy of this module lives in every demo that casts a wire-supplied id. They
# are identical apart from getgrocery's, which adds a JSON_SCHEMA_PATTERN constant
# it alone needs (T-050) — and until bin/check-demo-copies was written they were
# identical only by habit, with nothing failing the build when a copy drifted.
# Each demo is a standalone Rails app with its own Gemfile, so the alternative to
# a copy is publishing the guard in a shipped gem — a public-API decision, not a
# fix-wave one (K-607). Same arrangement as lib/pow_difficulty.rb and
# lib/equihash_register.rb.
#
# K-661: shape recognition below delegates to the `uuid` gem (pinned 2.3.9 —
# see the Gemfile comment for why). Its own `UUID.validate` is looser than
# this guard has ever been (it also accepts compact/un-hyphenated and
# `urn:uuid:` spellings), so PATTERN stays as the second, narrowing check —
# `valid?` requires both, which keeps the canonical-only rejection this
# module has always enforced (K-579) unchanged.
require "uuid"

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
    str = value.to_s
    !!(UUID.validate(str) && PATTERN.match?(str))
  end
end
