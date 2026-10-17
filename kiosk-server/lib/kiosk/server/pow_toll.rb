# frozen_string_literal: true

module Kiosk
  module Server
    # One proof-of-work toll on one request: `count` distinct, unspent, valid
    # proofs, or the error that sends the caller back. Shared by
    # {PowGate.gate} and {RegistrationPow}.
    class PowToll
      def initialize(spec:, fingerprint:, secret:, config:, on_bad_proof:)
        @spec         = spec
        @fingerprint  = fingerprint
        @secret       = secret
        @config       = config
        @on_bad_proof = on_bad_proof
      end

      # Returns `:proceed`, or raises PowRequired (402), BadRequest or Forbidden.
      def collect!(pow)
        validate_spec_params!
        submitted = PowGate.extract_proofs(pow)
        raise pow_required if submitted.empty?

        # `count` distinct, unspent, valid proofs; one wrong proof is a 403.
        accepted = {}
        submitted.each { |proof| accept(proof, accepted) }
        return :proceed if accepted.size >= count

        # Released, so the retry with fresh challenges is not blocked by our own claim.
        accepted.each_key { |id| spent_store.release(id) }
        raise pow_required
      end

      private

      def accept(proof, accepted)
        challenge = symbolize_keys(proof[:challenge] || proof['challenge'] || {})
        id        = challenge[:id]
        return if id.nil? || accepted.key?(id)

        check_challenge_params!(challenge)
        # Atomically claim the id as spent BEFORE the expensive verify.
        # A lost claim is a replay: skipped, not penalised.
        return unless spent_store.claim(id, challenge[:exp].to_i)

        settle(verify(challenge, proof[:nonce] || proof['nonce']), challenge, accepted)
      end

      def check_challenge_params!(challenge)
        return if challenge[:params].is_a?(Hash)

        raise Errors::BadRequest.new(
          'malformed PoW proof: challenge.params is missing or not an object',
          hint: PowGate::POW_HEADER_HINT
        )
      end

      # `expect`: honoured only at the difficulty live config demands now.
      def verify(challenge, nonce)
        ::Kiosk::Reputation::Challenge.verify(
          challenge: challenge, nonce: nonce, request_fingerprint: @fingerprint,
          secret: @secret, now: Time.now.to_i, expect: { alg: alg, params: params }
        )
      end

      def settle(outcome, challenge, accepted)
        case outcome
        when :ok
          accepted[challenge[:id]] = challenge[:exp].to_i
        when :bad_proof
          @on_bad_proof.call
          # The id stays consumed, so one challenge drives at most one verify.
          raise Errors::Forbidden.new('invalid proof of work', hint: PowGate::POW_INVALID_HINT)
        when :expired, :bad_sig, :bad_params
          # Not bad faith (clock skew, a difficulty change): release the claim
          # and re-challenge below.
          spent_store.release(challenge[:id])
        end
      end

      def validate_spec_params!
        return if ::Kiosk::Reputation::Backends.valid_params?(alg, params)

        raise Errors::ConfigurationError,
              "Kiosk::Server: the #{alg.to_s.inspect} proof-of-work backend refuses the configured " \
              "parameters #{params.inspect} — no proof solved at them could ever verify, so every " \
              'honest client would be told its correct proof was invalid. Fix the source of the ' \
              'parameters: `c.registration_pow_params` for POST /auth/register, or the `params:` ' \
              'your reputation_policy returns from #challenge_for.'
      end

      # Equihash has no difficulty dial: escalation is by proof count.
      def count
        [(@spec[:count] || @spec['count'] || 1).to_i, 1].max
      end

      # TTL scales with `count`, so the first expires no sooner than the last is solved.
      def pow_required
        ttl = @config.pow_ttl * count
        Errors::PowRequired.new(challenges: Array.new(count) { issue_challenge(ttl) })
      end

      def issue_challenge(ttl)
        ::Kiosk::Reputation::Challenge.issue(
          alg: @spec[:alg], params: @spec[:params], request_fingerprint: @fingerprint,
          secret: @secret, ttl: ttl, now: Time.now.to_i
        )
      end

      def alg    = @spec[:alg] || @spec['alg']
      def params = @spec[:params] || @spec['params']
      def spent_store = @config.pow_spent_store

      def symbolize_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.transform_keys(&:to_sym)
      end
    end
  end
end
