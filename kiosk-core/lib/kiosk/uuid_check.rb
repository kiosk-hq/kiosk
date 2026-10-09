# frozen_string_literal: true

module Kiosk
  # Shape check for wire-supplied uuids, so a malformed id is a typed 4xx rather
  # than a 500 from Postgres or a false ownership refusal from Active Record's
  # NULL cast. Format only: it says nothing about whether the row exists.
  module UuidCheck
    # Canonical 8-4-4-4-12 only, so a refusal can name exactly what to send.
    PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # {PATTERN} for a verb descriptor's `input_schema` (ECMA-262).
    JSON_SCHEMA_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

    def self.valid?(value)
      PATTERN.match?(value.to_s)
    end
  end
end
