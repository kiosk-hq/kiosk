# frozen_string_literal: true

module Kiosk
  # Canonical-uuid shape guard for identifiers that arrive on the wire.
  #
  # A provider that lets an agent-supplied id reach Postgres' `uuid` type has
  # two bad answers for a malformed literal, and this module exists so it can
  # give neither. A malformed id is a CLIENT mistake, and without a shape check
  # it is not reported as one:
  #
  #   * RAW SQL — an id interpolated into a `'<value>'::uuid` cast makes
  #     Postgres raise `PG::InvalidTextRepresentation` (SQLSTATE 22P02). That is
  #     not a Kiosk error, so it escapes the wire controller's rescue as a raw
  #     HTTP 500: a client mistake reported as a server fault, and one that
  #     leaks SQL internals ("invalid input syntax for type uuid") to the wire.
  #   * ACTIVE RECORD — the ORM CASTS a malformed literal to NULL rather than
  #     raising, so an owner-scoped query matches nothing and the caller is
  #     REFUSED. That is strictly worse for the assistant reading it than the
  #     500: a wrong 403/404 is indistinguishable from a genuine ownership
  #     refusal, so a caller with a typo'd id is told it does not own a row that
  #     never existed. Being on the ORM therefore STRENGTHENS the case for this
  #     guard rather than removing it.
  #
  # A handler checks the shape first and raises a typed 4xx instead.
  #
  # Format only — that an id is a well-formed uuid says nothing about whether
  # the row exists or is reachable by the caller; the ownership or membership
  # SQL still decides that.
  module UuidCheck
    # Canonical 8-4-4-4-12 hex form, the only shape an origin hands out
    # (`gen_random_uuid()` output, echoed back by the agent). Postgres itself
    # would also accept a few non-canonical spellings (brace-wrapped,
    # un-hyphenated); the canonical form is required deliberately, so a
    # rejection can name exactly what to send back.
    PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # The same shape written for JSON Schema, for the `input_schema` of a verb
    # descriptor that takes an id. ECMA-262, so `\h` and `\A`/`\z` are spelled
    # out; `^…$` is anchored because a JSON Schema `pattern` is a search, not a
    # full match. It lives beside {PATTERN} so the DECLARED contract and the
    # RUNTIME guard cannot drift apart unnoticed.
    #
    # It is a declaration, NOT a second enforcement point: kiosk-server
    # validates nothing against `input_schema`. This tells an assistant reading
    # `GET <endpoint>/schema` what shape to send, and {valid?} in the handler is
    # what actually rejects a bad one.
    JSON_SCHEMA_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

    # @param value [Object] the candidate id (usually a String off the wire)
    # @return [Boolean] true iff `value` is a canonical uuid literal
    def self.valid?(value)
      PATTERN.match?(value.to_s)
    end
  end
end
