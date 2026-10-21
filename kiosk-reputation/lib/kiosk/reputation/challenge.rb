# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'securerandom'

module Kiosk
  module Reputation
    # Stateless signed challenge for a `pow_required` answer: an HMAC over its fields
    # and the request fingerprint, so it needs no storage and binds to one request.
    # The caller keeps the spent-id set.
    module Challenge
      # Canonical-string delimiters; no field may contain one (see {delimiter_offence}).
      OUTER_DELIM = '|'
      PARAM_DELIM = ','
      KV_DELIM = '='

      DELIMITERS = [OUTER_DELIM, PARAM_DELIM, KV_DELIM].freeze

      # The signed fields, in canonical-string order. `salt` is base64.
      Fields = Data.define(:id, :alg, :params, :salt, :exp, :request_fingerprint)
      private_constant :Fields

      class << self
        # @return [Hash] signed challenge: {id:, alg:, params:, salt: <base64>, exp:, sig:}
        # @raise [ArgumentError] when a field carries a delimiter or `params` is not a Hash
        def issue(alg:, params:, request_fingerprint:, secret:, ttl:, # rubocop:disable Metrics/ParameterLists -- public keyword signature; every keyword is part of it.
                  now: Time.now.to_i,
                  salt: SecureRandom.bytes(16),
                  id: SecureRandom.uuid)
          fields = Fields.new(id:, alg:, params:, salt: Base64.strict_encode64(salt), exp: now + ttl, request_fingerprint:)
          offence = delimiter_offence(fields)
          raise ArgumentError, ambiguity_message(offence) if offence

          { id:, alg:, params:, salt: fields.salt, exp: fields.exp, sig: compute_sig(secret, fields) }
        end

        # Cheap checks run before the one expensive backend evaluation.
        # `expect:` is the `{alg:, params:}` the caller re-derived from its live config.
        # @return [Symbol] :ok | :bad_sig | :expired | :bad_params | :bad_proof
        def verify(challenge:, nonce:, request_fingerprint:, secret:, now:, expect: nil) # rubocop:disable Metrics/ParameterLists -- public keyword signature; every keyword is part of it.
          failure = check(challenge:, request_fingerprint:, secret:, now:, expect:)
          return failure if failure

          proof_valid?(fields_of(challenge, request_fingerprint), nonce) ? :ok : :bad_proof
        end

        # The cheap checks alone, so a caller can trust `id` and `exp` before it stores them.
        # @return [Symbol, nil] :bad_sig | :expired | :bad_params, or nil when the challenge is ours and live
        def check(challenge:, request_fingerprint:, secret:, now:, expect: nil)
          cheap_failure(fields_of(challenge, request_fingerprint), challenge[:sig].to_s, secret, now, expect)
        end

        private

        def fields_of(challenge, request_fingerprint)
          Fields.new(id: challenge[:id], alg: challenge[:alg], params: challenge[:params],
                     salt: challenge[:salt], exp: challenge[:exp], request_fingerprint:)
        end

        # The checks that cost no proof evaluation, in order. Nil when all pass.
        def cheap_failure(fields, sig, secret, now, expect)
          return :bad_sig unless constant_time_compare(compute_sig(secret, fields), sig)
          return :expired unless fields.exp.to_i > now.to_i
          # The signed string must have one pre-image.
          return :bad_params if delimiter_offence(fields)

          # The signature proves that we minted the challenge, not that we still demand it.
          :bad_params unless matches_expected?(expect, fields.alg, fields.params)
        end

        # The one expensive step: a single backend evaluation.
        def proof_valid?(fields, nonce)
          Backends.fetch(fields.alg).verify(salt: Base64.strict_decode64(fields.salt),
                                            params: fields.params.transform_keys(&:to_sym), nonce:)
        end

        def ambiguity_message(offence)
          "challenge field would make the signed canonical string ambiguous: #{offence}. " \
            'Fix the source of the value: the `alg`/`params` your reputation_policy returns ' \
            'from #challenge_for.'
        end

        # A delimiter inside a value gives the canonical string a second pre-image,
        # so one signature would cover two (alg, params) splits.
        def delimiter_offence(fields)
          outer_offence(fields) || params_offence(fields.params)
        end

        def outer_offence(fields)
          field, value = fields.to_h.except(:params).find { |_, text| text.to_s.include?(OUTER_DELIM) }
          "#{field} #{value.to_s.inspect} contains #{OUTER_DELIM.inspect}" if field
        end

        def params_offence(params)
          return nil unless params.is_a?(Hash)

          params.each do |key, value|
            DELIMITERS.each do |delim|
              return "params key #{key.to_s.inspect} contains #{delim.inspect}" if key.to_s.include?(delim)
              return "params value #{value.to_s.inspect} (key #{key.to_s.inspect}) contains #{delim.inspect}" if value.to_s.include?(delim)
            end
          end
          nil
        end

        # Compared in the signed rendering, so key order and key/value types never matter.
        def matches_expected?(expect, alg, params)
          return true if expect.nil?

          expected_alg = expect[:alg] || expect['alg']
          return false unless expected_alg.nil? || expected_alg.to_s == alg.to_s

          expected_params = expect[:params] || expect['params']
          return true if expected_params.nil?

          params_string(expected_params) == params_string(params)
        end

        def compute_sig(secret, fields)
          OpenSSL::HMAC.hexdigest('SHA256', secret, canonical_string(fields))
        end

        # id|alg|k=7,n=168|<salt_b64>|<exp>|<fingerprint>
        def canonical_string(fields)
          [fields.id, fields.alg, params_string(fields.params), fields.salt, fields.exp.to_s,
           fields.request_fingerprint].join(OUTER_DELIM)
        end

        def params_string(params)
          raise ArgumentError, "params must be a Hash (got #{params.inspect})" unless params.is_a?(Hash)

          params
            .sort_by { |k, _| k.to_s }
            .map { |k, v| "#{k}#{KV_DELIM}#{v}" }
            .join(PARAM_DELIM)
        end

        def constant_time_compare(expected, given)
          return false if expected.bytesize != given.bytesize

          OpenSSL.fixed_length_secure_compare(expected, given)
        end
      end
    end
  end
end
