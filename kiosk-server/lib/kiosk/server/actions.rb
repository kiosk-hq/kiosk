# frozen_string_literal: true

require "kiosk/server/verb_registry"

module Kiosk
  module Server
    # Registry of actions (`kind :action`): verbs that change something the
    # operator owns. The behaviour is {VerbRegistry}.
    module Actions
      SCOPE = :action
      Entry = VerbRegistry::Entry

      extend VerbRegistry
    end
  end
end
