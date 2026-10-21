# frozen_string_literal: true

require 'openssl'
require 'kiosk/test_helpers/dpop'

# One agent key for the suite, and the DPoP headers (RFC 9449) of a call that
# carries a token bound to it. Generated once: an RSA key costs tens of ms.
module DpopAgent
  KEY = OpenSSL::PKey::RSA.generate(2048)
  PEM = KEY.public_key.to_pem
  JKT = Kiosk::Server::SigningKey.new(KEY.public_key).kid

  def agent_key = KEY
  def agent_pem = PEM
  def agent_jkt = JKT

  # The `cnf` claim of a token bound to `key`.
  def cnf_for(key = KEY) = { jkt: Kiosk::Server::SigningKey.new(key.public_key).kid }

  # Rack env entries: `Authorization: DPoP <token>` and a proof for this method and URL.
  def dpop_env(token, method:, url:, key: KEY) = Kiosk::TestHelpers::Dpop.env(token, key, method:, url:)

  def dpop_headers(token, method:, url:, key: KEY) = Kiosk::TestHelpers::Dpop.headers(token, key, method:, url:)
end
