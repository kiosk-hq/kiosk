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
# the whole contract), so the superclass is whatever the app chooses — and
# here Kiosk::BookingsController and Kiosk::CatalogController subclass THIS
# class (K-1017). Widening it to ::Base therefore DOES reach them; what an
# assistant sees is unchanged because the wire answers JSON through the
# mount's own gates, never through a session.
#
# That sentence is CHECKED, not trusted (K-1021): bin/check-demo-copies reads
# the superclasses out of the fixture controllers beside this file and fails
# when the names or the superclass named here disagree. It is checked because
# the copy of this comment in the seven demos was, for weeks, false.
class ApplicationController < ActionController::Base
end
