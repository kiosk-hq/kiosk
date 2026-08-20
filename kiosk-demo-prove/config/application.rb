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

    # lib/ holds only rake tasks: the broker's four modules — the RSA issuer
    # key (the "ProveKey" skooti trusts, whose MATERIAL comes from
    # per-environment config; K-673), the operator registry, the claim catalog
    # and the callback poster — are application code and live under
    # app/models and app/services (K-502).
    #
    # Unlike the seven operator demos, prove declares NO
    # `config.autoload_once_paths`: nothing here is named during
    # initialization — config/environments/*.rb only publish
    # `Rails.configuration.x.prove.*` values, and the modules that read them
    # are reached from controllers and routes, both of which run after Rails
    # has set the reloadable autoloader up. So these four stay reloadable, and
    # the once-path is a workaround this app does not need.
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
