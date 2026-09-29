# frozen_string_literal: true

require "kiosk/server/verb_registry"

module Kiosk
  module Server
    # Registry of named queries — the sanctioned read surface that replaces raw
    # SQL. Agents call them by name with params (never SQL); the registered
    # handler runs the actual query with bound params. "Read-only" is a
    # convention the provider upholds (the registry does not enforce it), but the
    # agent can only ever supply a query name + param values — never SQL — so the
    # no-agent-SQL property holds regardless of what a handler does.
    #
    # `kind :query` on the declaration is what puts a verb HERE rather than in
    # {Actions}. Everything else — how a verb is declared, what the registry
    # does with it, and what each descriptor field means — is {VerbRegistry},
    # which both registries ARE.
    #
    # @example reading the registry
    #   Kiosk::Server::Queries.known             # => ["menu"]
    #   Kiosk::Server::Queries.describe("menu")  # => { name:, description:, reach:, … }
    #   Kiosk::Server::Queries.catalog           # => sorted Array of descriptors
    module Queries
      # Which registry a memoized descriptor belongs to ({SchemaSlots}), and the
      # noun this registry's refusals use.
      SCOPE = :query
      Entry = VerbRegistry::Entry

      extend VerbRegistry
    end
  end
end
