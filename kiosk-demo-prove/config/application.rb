require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module KioskDemoProve
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # prove_key.rb holds the RSA issuer key (the "ProveKey" skooti trusts). It is
    # a plain constant carrier, autoloaded by Zeitwerk — no ignore needed here.
    config.autoload_lib(ignore: %w[assets tasks])

    # This is a small web app (an ISSUER, not a Kiosk operator): it renders the
    # human verification page (HTML) AND serves the intake/callback JSON. Keep
    # the full middleware stack (NOT api_only) so ActionController::Base renders
    # the verification views out of the box.

    # Use SQL structure dump for parity with the sibling demos (pg_dump captures
    # the whole schema deterministically).
    config.active_record.schema_format = :sql
  end
end
