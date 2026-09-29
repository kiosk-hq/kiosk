# frozen_string_literal: true

require "kiosk/server/verb_registry"

module Kiosk
  module Server
    # Registry of named actions — the write surface. An action CHANGES something
    # the operator owns and returns what it did.
    #
    # `kind :action` on the declaration is what puts a verb HERE rather than in
    # {Queries}. Everything else — how a verb is declared, what the registry does
    # with it, and what each descriptor field means — is {VerbRegistry}, which
    # both registries ARE.
    #
    # @example reading the registry
    #   Kiosk::Server::Actions.known                   # => ["place_order"]
    #   Kiosk::Server::Actions.describe("place_order") # => { name:, description:, reach:, … }
    #   Kiosk::Server::Actions.catalog                 # => sorted Array of descriptors
    module Actions
      # Which registry a memoized descriptor belongs to ({SchemaSlots}), and the
      # noun this registry's refusals use.
      SCOPE = :action
      Entry = VerbRegistry::Entry

      extend VerbRegistry
    end
  end
end
