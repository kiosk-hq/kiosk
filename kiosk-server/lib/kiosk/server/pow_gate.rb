# frozen_string_literal: true

require "digest"
require "json"

module Kiosk
  module Server
    # PoW challenge-response gate (R2 protocol hook).
    #
    # Called by {WireController#run_command} AFTER identity resolution and BEFORE
    # {Executor.call}. When `Kiosk.configuration.reputation_policy` is nil
    # (the default), {.gate} returns `:proceed` immediately — zero overhead,
    # no `kiosk-reputation` references evaluated. This is the invariant that
    # keeps all existing tests, demos, and e2e flows byte-for-byte unchanged.
    #
    # == Soft dependency on kiosk-reputation
    #
    # `kiosk-server` does NOT hard-require `kiosk-reputation` at load time.
    # References to `Kiosk::Reputation::*` only appear inside the policy-present
    # branch of {.gate}. A host that sets `reputation_policy` is expected to
    # have `kiosk-reputation` (and its configured backend) already loaded; if it
    # isn't, {.gate} raises {Errors::ConfigurationError} with a clear message.
    #
    # == Anti-DoS cheap-before-expensive ordering
    #
    # On a submitted proof, `Kiosk::Reputation::Challenge.verify` enforces:
    #   1. HMAC sig + request-fingerprint binding (cheap constant-time compare)
    #   2. Expiry check (integer compare)
    #   3. Parameter re-derivation: the challenge must name the alg/params this
    #      server's live config demands right now, not merely params we once
    #      signed (K-541 — see the `expect:` argument below)
    #   4. Equihash backend eval (at n=168 k=7: ~18 ms + KB of RAM for a VALID
    #      proof — memory is the asymmetry, since SOLVING the same proof costs
    #      ~1.3 GiB)
    # A flood of forged, expired or off-spec proofs is rejected at step 1/2/3
    # without burning a backend evaluation. Cheap-before-expensive holds INSIDE
    # step 4 too (K-540): the backend checks structure before hashing and folds
    # the tree as it hashes, so a proof that gets this far and is simply wrong
    # costs ~0.3 ms, not the full ~18 ms.
    #
    # == Spent-id set
    #
    # Valid proofs are recorded in `config.pow_spent_store` (in-process TTL
    # store by default). That default makes single-use hold PER PROCESS only, so
    # a provider running MULTIPLE processes (`WEB_CONCURRENCY > 1`, or several
    # app hosts) **MUST** override it with a store shared by all of them —
    # otherwise one proof is accepted once per worker. This is a normative
    # requirement on the operator, not a tuning suggestion: protocol.md
    # Section 15.2 and the Section 16.1 operator profile state it. Ship-ready
    # override: {PowSpentStores::ActiveRecord} (K-738).
    module PowGate
      module_function

      # Compute the request fingerprint used for challenge binding — spec
      # design §3.4:
      #
      #     SHA256("<METHOD> <verb>\n<canonical args>")
      #
      # It covers the HTTP METHOD, the VERB NAME as it appears in the path,
      # and the canonical (key-order-independent) JSON serialisation of the
      # arguments. The proof travels in the `Kiosk-PoW` HEADER (ADR-0022), NOT
      # in the body, so all three are identical at issue time (no proof) and
      # verify time (proof in the header) — the fingerprint matches on retry.
      #
      # WHY METHOD AND VERB, AND NOT 0.3's `command`. Through 0.3 every read
      # was `POST <endpoint>/query` and every write `POST <endpoint>/run`, so
      # the method was a constant and the verb name lived INSIDE the arguments
      # — the digest could only reach it because the wire smuggled it back in
      # there. On the per-verb wire the name is a path segment and the method
      # carries the read/write fork, so both belong in the digest directly and
      # a proof solved for `GET /catalog?city=Lisbon` is spendable on nothing
      # else — not on `POST /catalog`, not on another verb with the same args.
      #
      # @param method [String] the HTTP request method ("GET", "POST", …)
      # @param verb   [String, Symbol] the wire verb name (the path segment)
      # @param body   [Hash, nil] the arguments
      # @return [String] SHA-256 hex digest
      def request_fingerprint(method:, verb:, body:)
        Digest::SHA256.hexdigest(
          "#{method.to_s.upcase} #{verb}\n#{canonical_json(body || {})}"
        )
      end

      # Gate a request through the reputation policy.
      #
      # @param identity [Kiosk::Identity]
      # @param command  [String, Symbol]  the gate/POLICY verb — one of
      #   {Executor::VERBS}; this is what `reputation_factors` and
      #   `Policy#challenge_for` branch on, and it is NOT what the fingerprint
      #   binds to
      # @param method   [String]          the HTTP request method — half of the
      #   §3.4 fingerprint
      # @param verb     [String, Symbol]  the WIRE verb name (the path segment)
      #   — the other half
      # @param body     [Hash, nil]       the verb args (the proof rides in the header, never here)
      # @param pow      [Array, Hash, nil] proof(s) parsed from the `Kiosk-PoW` header, or nil
      #
      # @return [:proceed]  when the request may proceed to {Executor}
      # @raise  [Errors::PowRequired]       (HTTP 402) when a challenge must be solved
      # @raise  [Errors::Forbidden]         (HTTP 403) when a submitted proof is invalid
      # @raise  [Errors::ConfigurationError] when the policy is set but pow_secret is
      #   missing, or the difficulty it demands is one no proof could satisfy (K-843)
      def gate(identity:, command:, body:, pow:, method: "POST", verb: nil)
        config = Kiosk.configuration
        policy = config.reputation_policy

        # ── Fast path (default, nil policy) ──────────────────────────────────
        # No kiosk-reputation references evaluated here. This is the ONLY path
        # exercised by the ~389 existing specs — byte-for-byte unchanged.
        return :proceed if policy.nil?

        # ── Policy present: guard checks ─────────────────────────────────────

        unless defined?(::Kiosk::Reputation)
          raise Errors::ConfigurationError,
            "Kiosk::Server: reputation_policy is set but kiosk-reputation is not loaded. " \
            "Add `require 'kiosk/reputation'` (and `gem 'kiosk-reputation'`) to your app."
        end

        secret = config.pow_secret
        if secret.nil? || secret.to_s.strip.empty?
          raise Errors::ConfigurationError,
            "Kiosk::Server: reputation_policy is set but pow_secret is nil or empty. " \
            "Set: Kiosk.configure { |c| c.pow_secret = ENV.fetch('KIOSK_POW_SECRET') }"
        end

        # ── Ask the policy ───────────────────────────────────────────────────

        fp      = request_fingerprint(method: method, verb: verb || command, body: body)
        factors = config.reputation_factors.call(identity: identity, verb: command.to_sym)
        spec    = policy.challenge_for(identity: identity, verb: command.to_sym, factors: factors)

        return :proceed if spec.nil?  # policy decided not to challenge this request

        result = enforce(
          spec:         spec,
          fingerprint:  fp,
          pow:          pow,
          secret:       secret,
          config:       config,
          on_bad_proof: -> { config.on_bad_proof.call(identity: identity) },
        )

        # ── Post-verify hook (duck-typed, opt-in) ────────────────────────────
        # We only reach here when `enforce` verified the submitted proof(s)
        # without raising (a real solve). Policies that define
        # #on_proof_verified (e.g. the count-based Backoff strategy) use this to
        # record the solve — e.g. grant the identity N ungated follow-up calls.
        # Duck-typed: a policy without the hook (RateAndReputation, the base
        # Policy, …) is completely unaffected. Never reached on the nil-spec
        # path above (no enforce ran → no new grant).
        if policy.respond_to?(:on_proof_verified)
          policy.on_proof_verified(identity: identity)
        end

        result
      end

      # Verify a set of submitted proofs against a `spec` bound to `fingerprint`,
      # or raise to demand them. Shared by the reputation gate ({.gate}) and the
      # registration gate ({RegistrationPow}), which differ only in how they
      # derive `spec`/`fingerprint` and whether a principal exists yet.
      #
      # @param spec         [Hash]     `{alg:, params:, count:}` (count defaults to 1)
      # @param fingerprint  [String]   request fingerprint the challenges bind to
      # @param pow          [Hash, nil] submitted proof(s)
      # @param secret       [String]   HMAC key for challenge sig
      # @param config       [Kiosk::Configuration]
      # @param on_bad_proof [#call]    invoked on a cryptographically invalid proof
      # @return [:proceed]
      # @raise  [Errors::PowRequired] (402) when more valid proofs are needed
      # @raise  [Errors::Forbidden]   (403) on a bad-faith (wrong) proof
      # @raise  [Errors::ConfigurationError] when `spec` names a difficulty the
      #   registered backend refuses (K-843)
      def enforce(spec:, fingerprint:, pow:, secret:, config:, on_bad_proof:)
        # ── Is this difficulty answerable at all? (K-843) ─────────────────────
        # Before anything is minted or verified. `spec` comes from operator
        # configuration — the policy's `challenge_for`, or
        # `config.registration_pow_params` — and nothing between here and the
        # wire re-reads it, so a degenerate `{n: 0}` produces challenges that
        # every honest solve fails. Refuse at the source instead, the way a
        # missing `pow_secret` already does.
        validate_spec_params!(spec)

        # ── How many independent proofs must this request carry? ──────────────
        # Equihash has no continuous difficulty dial — escalation is by PROOF
        # COUNT (N×PoW). Each challenge has a distinct salt, so there is no
        # amortisation across them. `count` defaults to 1 when spec omits it.
        count     = pow_count(spec)
        submitted = extract_proofs(pow)

        # ── No proof submitted — issue `count` fresh, independent challenges ──
        if submitted.empty?
          raise Errors::PowRequired.new(
            challenges: issue_challenges(count, spec, fingerprint, secret, config),
          )
        end

        # ── Proofs submitted — verify each. We need `count` DISTINCT, unspent,
        #    valid proofs to proceed. A single cryptographically WRONG proof is
        #    bad faith → 403 immediately.
        accepted = {} # challenge id => exp (dedup by id; ignores repeats)
        submitted.each do |proof|
          challenge = symbolize_keys(proof[:challenge] || proof["challenge"] || {})
          nonce     = proof[:nonce] || proof["nonce"]
          id        = challenge[:id]

          next if id.nil? || accepted.key?(id)

          # K-551/K-540 cheap structural pre-check: a well-formed proof echoes
          # the challenge object verbatim, `params` included. A missing/non-Hash
          # `params` would blow up in the challenge sig computation
          # (`nil.sort_by`) as an HTTP 500 — reject it here as a clean 400,
          # before the claim or any hash work.
          unless challenge[:params].is_a?(Hash)
            raise Errors::BadRequest.new(
              "malformed PoW proof: challenge.params is missing or not an object",
              hint: POW_HEADER_HINT,
            )
          end

          # K-542: atomically claim the id as spent BEFORE the expensive verify.
          # The FIRST of N racing submitters of one valid proof wins the claim
          # and proceeds; the losers get false and treat it as a replay — a
          # replayed/already-spent proof does not count toward the quota, but it
          # is NOT bad faith (an at-least-once HTTP retry may resend a served
          # proof), so skip it without penalty. Claiming before the verify also
          # means a bad proof's id is consumed (K-540): one issued challenge can
          # drive at most one verify.
          next unless config.pow_spent_store.claim(id, challenge[:exp].to_i)

          # Cheap sig + expiry + parameter checks first (inside
          # Challenge.verify), then the one cheap backend eval.
          #
          # K-541: `expect` is the alg/params THIS request's `spec` just
          # re-derived from live config (the policy, or
          # `config.registration_pow_params` for register) — the same source
          # `issue_challenges` mints from. Passing it means a challenge is
          # honoured only at the difficulty the server demands right now, not
          # merely at the difficulty its HMAC says we once minted.
          outcome = ::Kiosk::Reputation::Challenge.verify(
            challenge:            challenge,
            nonce:                nonce,
            request_fingerprint:  fingerprint,
            secret:               secret,
            now:                  Time.now.to_i,
            expect:               { alg: spec[:alg] || spec["alg"], params: spec[:params] || spec["params"] },
          )

          case outcome
          when :ok
            accepted[id] = challenge[:exp].to_i
          when :bad_proof
            on_bad_proof.call
            # The id stays CLAIMED (consumed): a proof that reached the backend
            # had a valid sig + live expiry, i.e. it targeted a real issued
            # challenge — burning it is what stops one free challenge from
            # fuelling unlimited garbage-proof verifies (K-540).
            #
            # K-512: a bare "wrong" is a dead end — a live agent that hand-rolled
            # its own Equihash solver got this 403 and had nothing to act on.
            # Name the ONE recovery step (run the shipped solver) without naming
            # WHICH check failed: the construction stays out of band, and the
            # agent is steered away from both improvised solvers and the
            # unvetted PyPI packages it otherwise reaches for.
            raise Errors::Forbidden.new("invalid proof of work", hint: POW_INVALID_HINT)
          when :expired, :bad_sig, :bad_params
            # Doesn't count; falls through to a fresh re-challenge below if the
            # quota isn't met. No on_bad_proof (honest clock skew / retry). The
            # sig didn't authenticate this challenge (or it is already dead), so
            # release the claim — never retain a forged-sig id (it would let an
            # attacker fill the spent store with junk exp anchors).
            #
            # :bad_params (K-541) joins them deliberately: a challenge naming
            # off-spec difficulty is either OURS from before a difficulty change
            # (an honest client, owed a fresh challenge at the new params — 402,
            # never 403) or forged with a leaked secret (which a 402 loop denies
            # just as effectively, at no cost to us since no hash loop ran).
            config.pow_spent_store.release(id)
          end
        end

        if accepted.size >= count
          # Quota met: the accepted ids stay claimed → single-use is enforced.
          :proceed
        else
          # Quota unmet: release the valid-but-insufficient proofs so a follow-up
          # retry (which is re-issued fresh challenges) is not blocked by our own
          # claim — preserving the no-burn-on-partial-submission property.
          accepted.each_key { |id| config.pow_spent_store.release(id) }
          raise Errors::PowRequired.new(
            challenges: issue_challenges(count, spec, fingerprint, secret, config),
          )
        end
      end

      # Parse the PoW proof(s) out of the `Kiosk-PoW` request HEADER
      # (ADR-0022). The proof is carried in a header, NOT in the request body:
      # the body is now ONLY verb args, so the challenge fingerprint binds to the
      # plain body untouched, and a GET (schema) can carry its proof too — a body
      # is not available on a GET.
      #
      # `raw` is the raw header value — for repeated same-name headers Rack joins
      # them with "\n" (`env["HTTP_KIOSK_POW"]`), so we split on "\n" first, then
      # normalise each line into an array of proofs. The forms accepted, all
      # flattening to one proofs list (b3 dual-accept):
      #   * one proof         `Kiosk-PoW: {"challenge":…,"nonce":…}`
      #   * a JSON array       `Kiosk-PoW: [{…},{…}]`
      #   * repeated lines     `Kiosk-PoW: {A}` / `Kiosk-PoW: {B}` (joined by "\n")
      #   * comma-combined     `Kiosk-PoW: {A},{B}` (RFC 7230 lets a proxy
      #     comma-join duplicate headers) — wrapping in `[…]` makes it a JSON array
      # Raw minified JSON is used (no base64): a minified proof is all-VCHAR /
      # no-newline, a valid HTTP header value.
      #
      # Returns `nil` when the header is absent/blank (the initial request must
      # still receive its normal 402 challenge). Malformed JSON raises
      # {Errors::BadRequest} with a hint naming the header + expected shape.
      #
      # @param raw [String, nil] the raw `Kiosk-PoW` header value (`HTTP_KIOSK_POW`)
      # @return [Array<Hash>, nil] a flat list of proofs, or nil when absent
      def proofs_from_header(raw)
        return nil if raw.nil?

        proofs = []
        raw.split("\n").each do |line|
          value = line.strip
          next if value.empty?

          wrapped = value.start_with?("[") ? value : "[#{value}]"
          parsed  = JSON.parse(wrapped, symbolize_names: true)
          proofs.concat(Array(parsed))
        end

        proofs.empty? ? nil : proofs
      rescue JSON::ParserError => e
        raise Errors::BadRequest.new(
          "malformed Kiosk-PoW header: #{e.message}",
          hint: POW_HEADER_HINT,
        )
      end

      # Human-readable description of the expected Kiosk-PoW header shape, echoed
      # in the 400 hint (K-451 style — name the shape so the agent can
      # self-correct).
      POW_HEADER_HINT =
        "the Kiosk-PoW header carries the proof(s) as raw minified JSON: a single " \
        "proof {\"challenge\": <the challenge object from the 402, echoed verbatim>, " \
        "\"nonce\": {\"indices\": […], \"header_nonce\"?}}, OR a JSON array of such " \
        "proofs [{…},{…}]. Repeated Kiosk-PoW header lines (one proof each) also " \
        "work. Solve every challenge issued in the pow_required 402 and echo it " \
        "back verbatim."

      # Hint on the 403 raised for a cryptographically WRONG proof (K-512).
      # Sibling of POW_HEADER_HINT: that one names the SHAPE a malformed proof
      # must take (400), this one names the TOOL a wrong proof must be produced
      # with (403). Deliberately says nothing about the Equihash construction,
      # the parameters, or which of the verifier's checks failed — the only
      # actionable fact is «use the shipped solver», and the solver itself is
      # the executable spec. The URL is first-party (kiosk.tech) so skill and
      # solver come from ONE origin we control; it MUST stay identical to the
      # URL the skill pins (K-490(e)) or the two drift.
      POW_INVALID_HINT =
        "solve with the reference solver at https://kiosk.tech/pow/solve.py — " \
        "a hand-written Equihash solver will not match this verifier"

      # ── Internal helpers (all module_function so they're callable from above) ──

      def blank?(obj)
        obj.nil? || (obj.respond_to?(:empty?) && obj.empty?)
      end

      def issue_challenge(spec, fp, secret, ttl)
        ::Kiosk::Reputation::Challenge.issue(
          alg:                  spec[:alg],
          params:               spec[:params],
          request_fingerprint:  fp,
          secret:               secret,
          ttl:                  ttl,
          now:                  Time.now.to_i,
        )
      end

      # Raise unless the registered backend accepts `spec`'s parameters (K-843).
      #
      # {Errors::ConfigurationError}, not a 4xx: no caller chose these values
      # and no caller can correct them. The message names the two places a
      # `spec` comes from, because the raise happens inside the gate and the
      # defect is in the operator's configuration.
      #
      # Backends that do not implement `.valid_params?` are unconstrained, and
      # `Backends.valid_params?` answers true for them — so this method is a
      # no-op for every backend but equihash today, by design.
      def validate_spec_params!(spec)
        alg    = spec[:alg]    || spec["alg"]
        params = spec[:params] || spec["params"]
        return if ::Kiosk::Reputation::Backends.valid_params?(alg, params)

        raise Errors::ConfigurationError,
          "Kiosk::Server: the #{alg.to_s.inspect} proof-of-work backend refuses the configured " \
          "parameters #{params.inspect} — no proof solved at them could ever verify, so every " \
          "honest client would be told its correct proof was invalid. Fix the source of the " \
          "parameters: `c.registration_pow_params` for POST /auth/register, or the `params:` " \
          "your reputation_policy returns from #challenge_for."
      end

      # Number of independent proofs the policy demands for this request.
      # Defaults to 1 (single-proof) when the spec omits `count`. Floored at 1.
      def pow_count(spec)
        n = (spec[:count] || spec["count"] || 1).to_i
        n < 1 ? 1 : n
      end

      # Issue `count` independent challenges — each gets its own random salt and
      # id (via Challenge.issue defaults) but binds to the SAME request
      # fingerprint, so all N must be solved to prove work for THIS request.
      #
      # The per-challenge TTL scales with `count`: a slow honest client solving
      # N proofs sequentially must not have the first challenge expire before it
      # reaches the last one. TTL = pow_ttl * count (min pow_ttl at count 1).
      def issue_challenges(count, spec, fp, secret, config)
        ttl = config.pow_ttl * [count, 1].max
        Array.new(count) { issue_challenge(spec, fp, secret, ttl) }
      end

      # Normalise the submitted `pow` field into a list of `{challenge:, nonce:}`
      # proofs. Accepts:
      #   * plural:   { proofs: [ {challenge:, nonce:}, ... ] }  (N×PoW wire)
      #   * singular: { challenge:, nonce: }                     (N=1 convenience)
      #   * a bare Array of proofs
      # Returns [] for anything blank/unrecognised.
      def extract_proofs(pow)
        return [] if blank?(pow)
        return pow if pow.is_a?(Array)
        return [] unless pow.is_a?(Hash)

        list = pow[:proofs] || pow["proofs"]
        return Array(list) if list
        return [pow] if pow[:challenge] || pow["challenge"]

        []
      end

      # Recursively serialise a value to JSON with all Hash keys sorted.
      # This ensures the fingerprint is key-order-independent.
      def canonical_json(obj)
        case obj
        when Hash
          pairs = obj.sort_by { |k, _| k.to_s }
                     .map { |k, v| "#{JSON.generate(k.to_s)}:#{canonical_json(v)}" }
          "{#{pairs.join(",")}}"
        when Array
          "[#{obj.map { |v| canonical_json(v) }.join(",")}]"
        else
          JSON.generate(obj)
        end
      end

      def symbolize_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.transform_keys(&:to_sym)
      end
    end
  end
end
