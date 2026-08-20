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
#
# A copy of this module lives in every demo that casts a wire-supplied id
# (skooti, hoteling, atablefor, tudu, philslist — K-581/K-582); they are
# identical apart from JSON_SCHEMA_PATTERN, which only getgrocery needs because
# only getgrocery declares an `input_schema` for an id param today (T-050).
# bin/check-demo-copies holds the other five to each other and records THIS copy
# as the one declared exception, so the divergence stays the one we chose.
# Each demo is a standalone Rails app with its own Gemfile, so the alternative to
# a copy is publishing the guard in a shipped gem — a public-API decision, not a
# fix-wave one. Same arrangement as app/services/pow_difficulty.rb and
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

  # The same shape written for JSON Schema (K-596). ECMA-262, so `\h` and `\A`/`\z`
  # are spelled out; `^…$` is anchored because json_schemer's `pattern` is a
  # search, not a full match. Lives here, next to PATTERN, so the DECLARED
  # contract and the RUNTIME guard cannot drift apart unnoticed.
  #
  # It is a declaration, NOT a second enforcement point: kiosk-server validates
  # nothing against `input_schema` today — `c.validate_requests` (slice-1)
  # covers the `Kiosk-PoW` header only, and policing verb arguments is T-045(a).
  # So this tells an assistant reading GET /kiosk/schema what shape to send, and
  # `UuidCheck.valid?` in the handler is what actually rejects a bad one.
  JSON_SCHEMA_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  # @param value [Object] the candidate id (usually a String off the wire)
  # @return [Boolean] true iff `value` is a canonical uuid literal
  def self.valid?(value)
    str = value.to_s
    !!(UUID.validate(str) && PATTERN.match?(str))
  end
end
