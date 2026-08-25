# frozen_string_literal: true

# Full ActionController::Base, not ::API.
#
# `rails new --api` generates `ApplicationController < ActionController::API`,
# and Devise's own controllers inherit from it — so the sign-in form 500s on
# `flash`, which ::API does not have. Turning `config.api_only` off restores the
# session/cookie/flash MIDDLEWARE; this restores the controller half. Both are
# needed, and this file is the second one.
#
# The agent-facing wire controllers inherit THIS class too, and that is by
# design: Kiosk ships a MIXIN, not a base class (`include Kiosk::Handler` is
# the whole contract — see Kiosk::CatalogController), so the superclass is
# whatever the app chooses. Widening it to ::Base therefore DOES reach
# Kiosk::BookingsController and Kiosk::CatalogController; what an assistant
# sees is unchanged because the wire answers JSON through the mount's own
# gates, never through a session (K-1017).
class ApplicationController < ActionController::Base
end
