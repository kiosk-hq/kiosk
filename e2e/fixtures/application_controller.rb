# frozen_string_literal: true

# Full ActionController::Base, not ::API.
#
# `rails new --api` generates `ApplicationController < ActionController::API`,
# and Devise's own controllers inherit from it — so the sign-in form 500s on
# `flash`, which ::API does not have. Turning `config.api_only` off restores the
# session/cookie/flash MIDDLEWARE; this restores the controller half. Both are
# needed, and this file is the second one.
#
# The agent-facing wire controllers are unaffected: they ship their own bases
# inside kiosk-server (ActionController::API), so nothing an assistant calls
# gains a cookie jar because a human page needed one.
class ApplicationController < ActionController::Base
end
