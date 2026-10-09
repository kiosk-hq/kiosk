# frozen_string_literal: true

require "kiosk/server/verb_registry"

module Kiosk
  module Server
    # The query registry (`kind :query`); everything else is {VerbRegistry}.
    # Read-only is a convention the provider upholds (the registry does not enforce it).
    module Queries
      SCOPE = :query
      Entry = VerbRegistry::Entry

      extend VerbRegistry
    end
  end
end
