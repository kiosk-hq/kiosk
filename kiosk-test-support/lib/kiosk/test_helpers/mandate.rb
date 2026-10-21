# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'jwt'
require 'securerandom'

module Kiosk
  module TestHelpers
    # The two closed AP2 v0.2 mandates an assistant signs to pay an operator's
    # checkout, as compact SD-JWTs: what an assistant following the skill sends.
    module Mandate
      module_function

      # @param checkout_jwt [String] the checkout an action answered, unchanged
      # @return [Hash] `checkout:` and `payment:`, each a compact SD-JWT
      def pay(key, checkout_jwt, instrument: 'on_file', lifetime: 600)
        checkout = JWT.decode(checkout_jwt, nil, false).first
        checkout_hash = digest(checkout_jwt)
        now = Time.now.to_i
        times = { iat: now, exp: now + lifetime }
        { checkout: sign(key, { vct: 'mandate.checkout.1', checkout_jwt:, checkout_hash:, **times }),
          payment: sign(key, { vct: 'mandate.payment.1', transaction_id: checkout_hash, payee: checkout['merchant'],
                               payment_amount: { amount: checkout['total_amount_cents'], currency: checkout['currency'] },
                               payment_instrument: { id: instrument, type: 'card' }, **times }) }
      end

      # A closed mandate: an SD-JWT whose one disclosure is `content`.
      def sign(key, content)
        disclosure = b64(JSON.generate([b64(SecureRandom.random_bytes(16)), content]))
        jwt = JWT.encode({ _sd_alg: 'sha-256', delegate_payload: [{ '...' => digest(disclosure) }] }, key, 'RS256',
                         { typ: 'dc+sd-jwt' })
        "#{jwt}~#{disclosure}~"
      end

      # The disclosed mandate of `sd_jwt`, unverified.
      def content(sd_jwt) = JSON.parse(Base64.urlsafe_decode64(sd_jwt.split('~')[1])).last

      def digest(text) = b64(Digest::SHA256.digest(text))

      def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
    end
  end
end
