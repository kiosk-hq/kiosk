# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'jwt'

module Kiosk
  module Server
    # The part of SD-JWT (RFC 9901) that an AP2 closed mandate needs: a compact
    # SD-JWT with no key-binding JWT, its issuer-signed JWT verified with one
    # key, and each disclosure put back in place of its digest.
    module SdJwt
      # The token is not a well-formed SD-JWT, or its disclosures do not match it.
      class Invalid < StandardError
      end

      SD_ALG = 'sha-256'

      module_function

      # @return [Array(Hash, Hash)] the payload with every disclosure in place, and the JWT header
      # @raise [Invalid, JWT::DecodeError]
      def verify(token, key:, algorithm:)
        jwt, disclosures = split(token)
        payload, header = ::JWT.decode(jwt, key, true, algorithms: [algorithm])
        sd_alg = payload.delete('_sd_alg') || SD_ALG
        raise Invalid, "_sd_alg is #{sd_alg.inspect}; only #{SD_ALG} is accepted" unless sd_alg == SD_ALG

        [disclose(payload, disclosures), header]
      end

      # The base64url SHA-256 of `text`: a disclosure's digest, and a mandate's reference.
      def digest(text) = Base64.urlsafe_encode64(Digest::SHA256.digest(text), padding: false)

      # `payload` with each disclosure in place. RFC 9901 §7.1: a disclosure that
      # no digest names, or two disclosures with one digest, refuse the token.
      def disclose(payload, disclosures)
        pending = disclosures.to_h { |d| [digest(d), decode_disclosure(d)] }
        raise Invalid, 'two disclosures have the same digest' if pending.size < disclosures.size

        resolved = resolve(payload, pending)
        raise Invalid, 'a disclosure is not named by any digest' unless pending.empty?

        resolved
      end

      # A compact SD-JWT ends in `~`: anything after it is a key-binding JWT,
      # and an empty part is a chain of SD-JWTs.
      def split(token)
        raise Invalid, 'an SD-JWT is a string' unless token.is_a?(String)

        jwt, *disclosures, binding = token.split('~', -1)
        raise Invalid, 'an SD-JWT ends with "~" and has no key-binding JWT' unless binding == ''
        raise Invalid, 'an SD-JWT has no empty part' if jwt.to_s.empty? || disclosures.any?(&:empty?)

        [jwt, disclosures]
      end

      def decode_disclosure(disclosure)
        array = JSON.parse(Base64.urlsafe_decode64(disclosure))
        return array if array.is_a?(Array) && [2, 3].include?(array.size) && array.first.is_a?(String)

        raise Invalid, 'a disclosure is an array of [salt, value] or [salt, name, value]'
      rescue ArgumentError, JSON::ParserError
        raise Invalid, 'a disclosure is base64url-encoded JSON'
      end

      def resolve(value, pending)
        case value
        when Hash  then resolve_object(value, pending)
        when Array then value.each_with_object([]) { |element, out| resolve_element(element, pending, out) }
        else value
        end
      end

      # The `_sd` digests become properties; a digest with no disclosure is a decoy.
      def resolve_object(object, pending)
        result = object.except('_sd').transform_values { |v| resolve(v, pending) }
        Array(object['_sd']).each do |d|
          disclosure = pending.delete(d) || next
          raise Invalid, 'an object disclosure is [salt, name, value]' unless disclosure.size == 3

          _salt, name, value = disclosure
          raise Invalid, "the disclosed name #{name.inspect} is already in the object" if result.key?(name)

          result[name] = resolve(value, pending)
        end
        result
      end

      # `{"...": digest}` becomes the disclosed element; one with no disclosure is left out.
      def resolve_element(element, pending, out)
        return out << resolve(element, pending) unless element.is_a?(Hash) && element.keys == ['...']

        disclosure = pending.delete(element['...']) || return
        raise Invalid, 'an array disclosure is [salt, value]' unless disclosure.size == 2

        out << resolve(disclosure.last, pending)
      end
      private_class_method :split, :decode_disclosure, :resolve, :resolve_object, :resolve_element
    end
  end
end
