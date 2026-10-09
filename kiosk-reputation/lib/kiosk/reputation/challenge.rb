# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

module Kiosk
  module Reputation
    # Stateless wire challenge for a `pow_required` answer: an HMAC over its fields
    # and the request fingerprint, so it needs no storage and binds to one request.
    # The caller keeps the spent-id set.
    module Challenge
      # Canonical-string delimiters; no field may contain one (see {delimiter_offence}).
      OUTER_DELIM = "|"
      PARAM_DELIM = ","
      KV_DELIM = "="

      DELIMITERS = [OUTER_DELIM, PARAM_DELIM, KV_DELIM].freeze

      class << self
        # @return [Hash] wire challenge: {id:, alg:, params:, salt: <base64>, exp:, sig:}
        # @raise [ArgumentError] when a field carries a delimiter or `params` is not a Hash
        def issue(alg:, params:, request_fingerprint:, secret:, ttl:,
                  now: Time.now.to_i,
                  salt: SecureRandom.bytes(16),
                  id: SecureRandom.uuid)
          salt_b64 = Base64.strict_encode64(salt)
          exp      = now + ttl

          offence = delimiter_offence(id, alg, params, salt_b64, exp, request_fingerprint)
          if offence
            raise ArgumentError,
              "challenge field would make the signed canonical string ambiguous: #{offence}. " \
              "Fix the source of the value: the `alg`/`params` your reputation_policy returns " \
              "from #challenge_for, or `c.registration_pow_params` for POST /auth/register."
          end

          sig      = compute_sig(secret, id, alg, params, salt_b64, exp, request_fingerprint)

          { id: id, alg: alg, params: params, salt: salt_b64, exp: exp, sig: sig }
        end

        # Cheap checks run before the one expensive backend evaluation.
        # `expect:` is the `{alg:, params:}` the caller re-derived from its live config.
        # @return [Symbol] :ok | :bad_sig | :expired | :bad_params | :bad_proof
        def verify(challenge:, nonce:, request_fingerprint:, secret:, now:, expect: nil)
          id       = challenge[:id]
          alg      = challenge[:alg]
          params   = challenge[:params]
          salt_b64 = challenge[:salt]
          exp      = challenge[:exp]
          stored_sig = challenge[:sig].to_s

          # --- Step 1 (CHEAP): sig check + request binding ---
          expected_sig = compute_sig(secret, id, alg, params, salt_b64, exp, request_fingerprint)
          return :bad_sig unless constant_time_compare(expected_sig, stored_sig)

          # --- Step 2 (CHEAP): expiry check ---
          return :expired unless exp.to_i > now.to_i

          # --- Step 3a (CHEAP): the signed string must have ONE pre-image ---
          return :bad_params if delimiter_offence(id, alg, params, salt_b64, exp, request_fingerprint)

          # --- Step 3b (CHEAP): the sig proves we minted it, not that we still demand it ---
          return :bad_params unless matches_expected?(expect, alg, params)

          # --- Step 4 (EXPENSIVE): one backend eval ---
          raw_salt   = Base64.strict_decode64(salt_b64)
          sym_params = symbolize_keys(params)
          result     = Backends.fetch(alg).verify(salt: raw_salt, params: sym_params, nonce: nonce)
          result ? :ok : :bad_proof
        end

        private

        # A delimiter inside a value gives the canonical string a second pre-image,
        # so one signature would cover two (alg, params) splits.
        def delimiter_offence(id, alg, params, salt_b64, exp, request_fingerprint)
          { "id" => id, "alg" => alg, "salt" => salt_b64,
            "exp" => exp, "request_fingerprint" => request_fingerprint }.each do |field, value|
            if value.to_s.include?(OUTER_DELIM)
              return "#{field} #{value.to_s.inspect} contains #{OUTER_DELIM.inspect}"
            end
          end

          return nil unless params.is_a?(Hash)

          params.each do |key, value|
            DELIMITERS.each do |delim|
              return "params key #{key.to_s.inspect} contains #{delim.inspect}" if key.to_s.include?(delim)

              if value.to_s.include?(delim)
                return "params value #{value.to_s.inspect} (key #{key.to_s.inspect}) contains #{delim.inspect}"
              end
            end
          end

          nil
        end

        # Compared in the signed rendering, so key order and key/value types never matter.
        def matches_expected?(expect, alg, params)
          return true if expect.nil?

          expected_alg = expect[:alg] || expect["alg"]
          unless expected_alg.nil? || expected_alg.to_s == alg.to_s
            return false
          end

          expected_params = expect[:params] || expect["params"]
          return true if expected_params.nil?

          params_string(expected_params) == params_string(params)
        end

        def compute_sig(secret, id, alg, params, salt_b64, exp, request_fingerprint)
          OpenSSL::HMAC.hexdigest("SHA256", secret, canonical_string(id, alg, params, salt_b64, exp, request_fingerprint))
        end

        # id|alg|k=7,n=168|<salt_b64>|<exp>|<fingerprint>
        def canonical_string(id, alg, params, salt_b64, exp, request_fingerprint)
          [id, alg, params_string(params), salt_b64, exp.to_s, request_fingerprint].join(OUTER_DELIM)
        end

        def params_string(params)
          unless params.is_a?(Hash)
            raise ArgumentError, "params must be a Hash (got #{params.inspect})"
          end

          params
            .sort_by { |k, _| k.to_s }
            .map { |k, v| "#{k}#{KV_DELIM}#{v}" }
            .join(PARAM_DELIM)
        end

        def constant_time_compare(a, b)
          return false if a.bytesize != b.bytesize
          OpenSSL.fixed_length_secure_compare(a, b)
        end

        def symbolize_keys(hash)
          hash.transform_keys(&:to_sym)
        end
      end
    end
  end
end
