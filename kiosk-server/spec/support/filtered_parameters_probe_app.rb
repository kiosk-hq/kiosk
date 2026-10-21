# frozen_string_literal: true

# The fresh-host probe behind spec/kiosk/server/engine_filtered_parameters_spec.rb —
# run as a SUBPROCESS, never loaded into the RSpec process. It boots a real
# Rails::Application with kiosk-server loaded and NOTHING else (no
# config/initializers/filter_parameter_logging.rb, so what the log shows is
# the engine's own doing), drives one request per credential-bearing wire
# field through the full Rack stack at the `info` level a deployed origin
# runs at, and prints the captured log plus the values it sent as one JSON
# report for the spec to assert on.
#
# Out-of-process for the reason engine_mount_probe_app.rb gives: booting
# Rails inside the suite process mutates it globally, and this probe also
# needs Rails.logger to be its own StringIO.

require 'bundler/setup'
require 'json'
require 'stringio'
# The railtie a real host gets from `rails/all`: it is what hands
# ActionController the logger the request log is written through, so without
# it this probe would measure a silent log rather than a filtered one.
require 'action_controller/railtie'
require 'kiosk/server'
require 'rack/mock'

LOG = StringIO.new

class ProbeApp < Rails::Application
  config.eager_load = false
  config.paths['config'] << File.expand_path('config', __dir__)
  config.hosts.clear
  config.secret_key_base = 'filtered-parameters-probe'
  config.logger = ActiveSupport::Logger.new(LOG)
  config.log_level = :info
end
Rails.application.initialize!

Kiosk.configure do |c|
  c.issuer      = 'http://localhost'
  c.user_model  = 'User'
  c.signing_key = Kiosk::Server::SigningKey.generate
end

Rails.application.routes.draw do
  mount Kiosk::Server::Engine => '/kiosk'
end

# One distinguishable value per field, so the spec can look for the value
# itself rather than for a shape. `client_assertion_type` is the CONTROL: it
# names a standard, it is no credential, and it must reach the log in the
# clear, which is also what proves the log carries parameter values at all.
SENT = {
  'client_assertion_type' => 'SENTINEL-assertion-type-a1',
  'client_assertion' => 'SENTINEL-client-assertion-b2',
  'new_client_assertion' => 'SENTINEL-new-client-assertion-h8',
  'code' => 'SENTINEL-link-code-c3',
  'device_code' => 'SENTINEL-device-code-d4',
  'kyc_jws' => 'SENTINEL-kyc-attestation-e5',
  'checkout_mandate' => 'SENTINEL-checkout-mandate-f6',
  'payment_mandate' => 'SENTINEL-payment-mandate-g7'
}.freeze

# The access token travels in a header rather than in a parameter, so it is
# outside `filter_parameters` entirely. Sent on one request so the spec can
# say what the request log does with it.
BEARER = 'SENTINEL-access-token-i9'

def post_json(path, body, bearer: false)
  env = Rack::MockRequest.env_for(
    "http://localhost#{path}",
    method: 'POST', input: JSON.generate(body), 'CONTENT_TYPE' => 'application/json'
  )
  env['HTTP_AUTHORIZATION'] = "Bearer #{BEARER}" if bearer
  Rails.application.call(env).last.close
end

def post_form(path, body)
  env = Rack::MockRequest.env_for("http://localhost#{path}", method: 'POST', params: body)
  Rails.application.call(env).last.close
end

post_json '/kiosk/auth/rotate',   SENT.slice('client_assertion_type', 'client_assertion', 'new_client_assertion')
post_json '/kiosk/auth/claim',    SENT.slice('code', 'client_assertion_type', 'client_assertion')
post_json '/kiosk/agents/kyc',    SENT.slice('kyc_jws')
post_json '/kiosk/pay',
          SENT.slice('checkout_mandate', 'payment_mandate'),
          bearer: true
post_form '/kiosk/oauth/token',
          SENT.slice('device_code', 'client_assertion_type', 'client_assertion')
              .merge('grant_type' => 'urn:ietf:params:oauth:grant-type:device_code')

puts JSON.generate('log' => LOG.string, 'sent' => SENT, 'bearer' => BEARER)
