# Full ActionController::Base (not ::API): Devise's session controllers
# inherit from here, and the human-facing pages need cookies/flash/CSRF.
# The Kiosk wire controllers ship their own bases inside kiosk-server.
class ApplicationController < ActionController::Base
end
