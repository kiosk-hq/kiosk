# frozen_string_literal: true

require 'base64'
require 'json'
require 'jwt'
require 'openssl'
require 'kiosk/test_helpers/dpop'

# One agent key for the suite, and the DPoP headers (RFC 9449) of a call that
# carries a token bound to it.
module DpopAgent
  KEY = OpenSSL::PKey.generate_key('ED25519')
  PEM = KEY.public_to_pem
  JKT = Kiosk::TestHelpers::Dpop.thumbprint(KEY)

  def agent_key = KEY
  def agent_pem = PEM
  def agent_jkt = JKT

  # The `cnf` claim of a token bound to `key`.
  def cnf_for(key = KEY) = { jkt: Kiosk::TestHelpers::Dpop.thumbprint(key) }

  # Rack env entries: `Authorization: DPoP <token>` and a proof for this method and URL.
  def dpop_env(token, method:, url:, key: KEY) = Kiosk::TestHelpers::Dpop.env(token, key, method:, url:)

  def dpop_headers(token, method:, url:, key: KEY) = Kiosk::TestHelpers::Dpop.headers(token, key, method:, url:)

  # A JWS whose header names `alg`, signed by `key` with the algorithm of its own type.
  def mislabelled_jws(payload, key, alg, header = {})
    input = [header.merge(alg: alg), payload].map { Base64.urlsafe_encode64(JSON.generate(it), padding: false) }.join('.')
    signature = JWT::JWA.resolve(Kiosk::TestHelpers::Dpop.algorithm(key)).sign(data: input, signing_key: key)
    "#{input}.#{Base64.urlsafe_encode64(signature, padding: false)}"
  end
end
