# frozen_string_literal: true

# Shape check for the uuids that arrive from the wire.
#
# hoteling takes agent-supplied ids on the wire — the `booking_id` arg of
# confirm_booking, and the `{"booking_id":…}` entry inside a signed cart
# mandate's line_items that ValidatingBookingProvider prices at capture. BOTH
# modes below are live here: the verb handlers are ActiveRecord, while
# app/services/validating_booking_provider.rb still builds `::uuid` casts
# on the pay path — and there a 500 is the worst possible answer, because an
# assistant cannot tell it from "the charge may have happened".
#
# TWO failure modes, and this guard answers both. A malformed id is a CLIENT
# mistake, and neither of the things that happen without the check reports it
# as one:
#
#   * RAW SQL — an id interpolated into a `'<value>'::uuid` cast makes Postgres
#     raise `PG::InvalidTextRepresentation` (SQLSTATE 22P02), which is not a
#     `Kiosk::Server::Errors::Base` and so escapes the wire controller's rescue
#     as a raw HTTP 500: a client mistake reported as a server fault, and one
#     that leaks SQL internals ("invalid input syntax for type uuid") to the
#     wire.
#   * ACTIVE RECORD — the ORM CASTS a malformed literal to NULL rather
#     than raising, so the owner-scoped query matches nothing and the caller is
#     REFUSED. That is strictly worse for the agent reading it than the 500: a
#     wrong 403/404 is indistinguishable from a genuine ownership refusal, so a
#     caller with a typo'd id is told it does not own a row that never existed.
#     Moving off raw SQL therefore STRENGTHENS the case for this guard instead
#     of retiring it.
#
# Callers validate the shape first and raise a typed 4xx instead.
#
# Format only — that an id is a well-formed uuid says nothing about whether the
# row exists or belongs to the caller; the ownership/state SQL still decides that.
#
# A copy of this module lives in every demo that casts a wire-supplied id.
# They are identical apart from getgrocery's, which adds a
# JSON_SCHEMA_PATTERN constant it alone needs; bin/check-demo-copies is what
# keeps the copies from drifting apart. Each demo is a standalone Rails app
# with its own Gemfile, so the alternative to a copy is publishing the guard
# in a shipped gem — a public-API decision rather than a local one. Same
# arrangement as app/services/pow_difficulty.rb and
# script/equihash_register.rb.
#
# NOTHING BUT PATTERN BACKS THIS, deliberately. ANDing it with the archived
# `uuid` gem's own validator would be a NO-OP: that validator accepts the
# canonical form with an OPTIONAL `urn:uuid:` prefix, case-insensitively, plus
# the compact 32-hex spelling — a strict SUPERSET of PATTERN, and a looser
# second test cannot narrow the first. Measured — 100,000 random
# candidates and eighteen hand-picked edges (compact, `urn:uuid:`,
# brace-wrapped, empty, non-hex, upper-case, embedded newline): ZERO
# disagreements between the conjunction and PATTERN alone; and of 200,000
# canonical-shaped strings that PATTERN matches, the gem rejected none. On a
# public repository it was pure cost — a dependency audit is the first thing
# a reader runs.

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
    PATTERN.match?(str)
  end
end
