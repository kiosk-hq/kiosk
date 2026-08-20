# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "openssl"
require "securerandom"
require "uri"
require "jwt"
require "kiosk/pow/equihash"

module Kiosk
  module Redteam
    # HTTP driver for the Kiosk provider API.
    #
    # Covers the full agent flow:
    #   register → kyc → query / run → pay
    #
    # EVERY tolled step pays its toll. `register`, `query`, `run` and `pay` all
    # route their answer through {#with_pow_retry}: a `pow_required` 402 is
    # solved once and the identical request re-sent with the proofs in the
    # `Kiosk-PoW` header. A toll is a price, not a refusal — an attacker pays
    # it, so a harness that cannot pay it cannot attack a tolled verb (K-760).
    #
    # Two registration entry points:
    #   - {#register_raw} — always returns a {Response}; use in scenarios that
    #     assert a rejection (e.g. RegistrationWithoutPow).
    #   - {#register!}    — returns a {Principal} on HTTP 201; raises otherwise.
    #
    # Wire formats mirror kiosk-demo-skooti/script/rental_flow.rb and
    # kiosk-demo-getgrocery/script/getgrocery_flow.rb exactly.
    class Client
      # Raised by {#register!} when the server does not respond 201.
      class RegistrationError < StandardError; end

      def initialize(base_url:)
        @base_url = base_url.chomp("/")
      end

      # ── Registration ──────────────────────────────────────────────────────

      # Low-level registration — always returns a {Response} regardless of
      # the HTTP status.  Use this in scenarios that expect a rejection
      # (e.g. RegistrationWithoutPow).
      #
      # @param name           [String]           agent display name
      # @param role           [String]           INERT — accepted but never sent
      #   on the wire. The server pins the role during the proof-of-possession
      #   handshake (see {#build_register}); this kwarg is threaded through but
      #   never reaches the register body. To adversarially inject a role, use
      #   `wire_role:` instead. Kept only so callers don't have to change.
      # @param pow_difficulty [Integer]          INERT — accepted but never read
      #   by the Client. PoW solving is driven entirely by the server's 402
      #   Equihash challenges (see {#build_register}), not by this integer.
      #   Kept only so callers/scenarios that thread `profile.pow_difficulty`
      #   through don't have to change; scenarios read that value directly to
      #   decide applicability (e.g. RegistrationWithoutPow).
      # @param pow            [:solve, :skip, String]
      #   :solve  — auto-solve each 402 Equihash challenge and resubmit
      #   :skip   — never include the pow field (test missing-proof)
      #   String  — send this exact value verbatim (test bad-proof)
      # @param wire_role      [String, nil]
      #   ADVERSARIAL: when set, inject a `role` field into the register body to
      #   simulate an agent trying to self-select a privileged role. The server
      #   MUST ignore it (the role is pinned server-side). nil = send nothing.
      # @return [Response]
      def register_raw(name:, role: "customer", pow_difficulty: 0, pow: :solve, wire_role: nil)
        response, _key = build_register(name:, role:, pow_difficulty:, pow:, wire_role:)
        response
      end

      # High-level registration — returns a {Principal} on HTTP 201 or raises.
      #
      # @param (see #register_raw)
      # @return [Principal]
      # @raise [RegistrationError] when the server responds with a non-201 status
      def register!(name:, role: "customer", pow_difficulty: 0, pow: :solve)
        response, key = build_register(name:, role:, pow_difficulty:, pow:)
        unless response.status == 201
          raise RegistrationError,
            "register! expected 201, got #{response.status}: #{response.body.inspect}"
        end
        Principal.new(
          agent_id: response.body.fetch("agent_id"),
          user_id:  response.body.fetch("user_id"),
          token:    response.body.fetch("access_token"),
          rsa_key:  key,
        )
      end

      # ── KYC ───────────────────────────────────────────────────────────────

      # Submit a KYC attestation JWS for the given principal.
      #
      # @param principal       [Principal]
      # @param attestation_jws [String] pre-built JWS from the KYC issuer
      # @return [Response]
      def kyc(principal, attestation_jws:)
        post_json(
          "/kiosk/agents/kyc",
          { kyc_jws: attestation_jws },
          bearer: principal.token,
        )
      end

      # ── Exec verbs ────────────────────────────────────────────────────────

      # Execute a named query (read-only).
      #
      # PROTOCOL 0.4: a query is `GET <endpoint>/<query-name>` with its
      # arguments in the QUERY STRING. There is no `/kiosk/query` endpoint and
      # no `name` field — the name is the path segment, which is also what the
      # PoW fingerprint binds to.
      #
      # A tolled query is ATTACKED, not stalled around: a `pow_required` 402 is
      # answered with one solve-and-resend ({#with_pow_retry}, K-760).
      #
      # @param principal [Principal]
      # @param name      [String]  query name registered by the provider
      # @param params    [Hash]    additional query parameters
      # @return [Response]
      def query(principal, name:, **params)
        path     = "/kiosk/#{name}"
        response = get_json(path, params: params, bearer: principal.token)
        with_pow_retry(response) do |pow|
          get_json(path, params: params, bearer: principal.token, pow: pow)
        end
      end

      # Execute a named action (write).
      #
      # PROTOCOL 0.4: an action is `POST <endpoint>/<action-name>` whose body
      # is the arguments and nothing else.
      #
      # A tolled action is ATTACKED, not stalled around: a `pow_required` 402 is
      # answered with one solve-and-resend ({#with_pow_retry}, K-760).
      #
      # @param principal [Principal]
      # @param name      [String] action name registered by the provider
      # @param args      [Hash]   action arguments
      # @return [Response]
      def run(principal, name:, **args)
        path     = "/kiosk/#{name}"
        response = post_json(path, args, bearer: principal.token)
        with_pow_retry(response) do |pow|
          post_json(path, args, bearer: principal.token, pow: pow)
        end
      end

      # Sign and POST a pay command with RS256-signed intent + cart + payment mandates.
      #
      # The mandates are signed with the principal's RSA private key so the
      # provider can verify the principal authored them.  Use {#sign_mandate}
      # directly to craft forged / tampered mandates.
      #
      # The payment mandate is built automatically from the cart payload
      # (cart_mandate_id = cart[:id], amount_cents = cart[:total_amount_cents],
      # currency = cart[:currency], iss = cart[:iss]).
      #
      # @param principal      [Principal]
      # @param intent         [Hash]   intent mandate payload
      # @param cart           [Hash]   cart mandate payload
      # @param payment_method [String] payment instrument reference (default "pm_demo")
      # @return [Response]
      def pay(principal, intent:, cart:, payment_method: "pm_demo")
        payment = build_payment_mandate(principal, cart: cart, payment_method: payment_method)
        # SIGN ONCE, then reuse the identical body on the PoW retry. The
        # challenge binds to a fingerprint of METHOD + verb + canonical body
        # (spec §3.4), and re-signing would mint fresh mandate ids and `iat`s —
        # a different body, so the proof we just paid for would bind to nothing
        # and the provider would re-challenge forever.
        body = {
          intent_mandate_jws:  sign_mandate(principal, intent),
          cart_mandate_jws:    sign_mandate(principal, cart),
          payment_mandate_jws: sign_mandate(principal, payment),
        }
        response = post_json("/kiosk/pay", body, bearer: principal.token)
        with_pow_retry(response) do |pow|
          post_json("/kiosk/pay", body, bearer: principal.token, pow: pow)
        end
      end

      # Build a payment mandate payload bound to the given cart and principal.
      #
      # Accepts both symbol-keyed and string-keyed cart hashes (flow drivers use
      # symbols; test support stubs may use strings).
      #
      # @param principal      [Principal]
      # @param cart           [Hash]   cart mandate payload (must have :id or "id",
      #                                :total_amount_cents or "total_amount_cents",
      #                                :currency or "currency", :iss or "iss")
      # @param payment_method [String] payment instrument reference
      # @return [Hash] unsigned payment mandate payload
      def build_payment_mandate(principal, cart:, payment_method: "pm_demo")
        now = Time.now.to_i
        {
          id:              SecureRandom.uuid,
          cart_mandate_id: cart[:id] || cart["id"],
          user_id:         principal.user_id,
          agent_id:        principal.agent_id,
          iss:             cart[:iss] || cart["iss"],
          payment_method:  payment_method,
          amount_cents:    cart[:total_amount_cents] || cart["total_amount_cents"],
          currency:        cart[:currency] || cart["currency"],
          exp:             now + 600,
          iat:             now,
        }
      end

      # Sign an arbitrary payload as an RS256 JWS using the principal's private
      # RSA key.  Exposed so scenarios can craft forged / tampered mandates.
      #
      # @param principal [Principal]
      # @param payload   [Hash] JWT claims
      # @return [String] compact JWS (header.payload.signature)
      def sign_mandate(principal, payload)
        JWT.encode(payload, principal.rsa_key, "RS256")
      end

      # Post a pay command with pre-built JWS strings, bypassing signing.
      #
      # Use this instead of {#pay} when you already hold raw JWS strings
      # (e.g. in {Scenarios::MandateReplay} where we re-submit A's exact JWS
      # under B's bearer token to test mandate non-transferability).
      #
      # @param principal   [Principal] whose bearer token to use
      # @param intent_jws  [String]    pre-built intent mandate JWS
      # @param cart_jws    [String]    pre-built cart mandate JWS
      # @param payment_jws [String]    pre-built payment mandate JWS
      # @return [Response]
      def pay_raw(principal, intent_jws:, cart_jws:, payment_jws:)
        body = {
          intent_mandate_jws:  intent_jws,
          cart_mandate_jws:    cart_jws,
          payment_mandate_jws: payment_jws,
        }
        response = post_json("/kiosk/pay", body, bearer: principal.token)
        with_pow_retry(response) do |pow|
          post_json("/kiosk/pay", body, bearer: principal.token, pow: pow)
        end
      end

      private

      # Shared implementation for both #register_raw and #register!.
      # Returns [Response, OpenSSL::PKey::RSA] — the key is discarded by
      # register_raw (it was for a rejected registration) but captured by
      # register! to build the Principal.
      #
      # Registration is now a proof-of-possession handshake: fetch a single-use
      # challenge, sign it (origin-bound via `aud`), then POST the signature.
      # `name`/`role` are no longer sent on the wire (the server pins the role),
      # and `pow_difficulty` is never read — PoW is driven off the server's 402
      # challenges below. These kwargs are kept inert so existing
      # callers/scenarios don't have to change.
      def build_register(name:, role:, pow_difficulty:, pow:, wire_role: nil)
        key = OpenSSL::PKey::RSA.generate(2048)
        pem = key.public_key.to_pem
        body = { public_key: pem, signed: build_pop(key, pem) }
        # ADVERSARIAL injection: a real agent never sends this; PrivilegeSelfSelection
        # sets it to prove the server ignores a client-chosen role.
        body[:role] = wire_role unless wire_role.nil?

        # Negative-test strategies short-circuit: :skip omits the proof
        # (missing-proof test), a verbatim String sends a malformed Kiosk-PoW
        # header value (bad-proof test). Both expect rejection, so we post once
        # and return. The proof rides in the Kiosk-PoW header now (ADR-0022), not
        # the body.
        if pow == :skip
          return [post_json("/kiosk/auth/register", body), key]
        elsif pow.is_a?(String)
          return [post_json("/kiosk/auth/register", body, pow: pow), key]
        end

        # :solve — post; if the provider gates registration (402 Equihash), solve
        # every challenge and resubmit the SAME signed body, sending the proof(s)
        # in the Kiosk-PoW request header as raw JSON. Since K-760 that is the
        # SHARED {#with_pow_retry}, not a branch that lives only here — register
        # was the only tolled verb this client could pay, which is precisely
        # what made a tolled query/action unattackable.
        resp = post_json("/kiosk/auth/register", body)
        resp = with_pow_retry(resp) do |pow|
          post_json("/kiosk/auth/register", body, pow: pow)
        end
        [resp, key]
      end

      # ONE bounded 402-PoW retry: solve every challenge the provider issued and
      # re-send the IDENTICAL request with the proofs in the `Kiosk-PoW` header.
      # Shared by registration and by every wire verb (K-760).
      #
      # WHY A HARNESS PAYS TOLLS. A `pow_required` 402 is a price, not a refusal
      # (K-736) — so an attacker pays it, and a harness that cannot pay it
      # cannot attack a tolled verb AT ALL. Until this method existed the solve
      # branch lived inside {#build_register}, so the day an operator tolled a
      # real query or action every scenario touching it went from "tested and
      # blocked" to "cannot be tested" — total loss of coverage on exactly the
      # surface the battery exists to exercise.
      #
      # BOUNDED BY CONSTRUCTION: exactly one solve-and-resend per call, no
      # loop. A provider that re-demands the toll gets the second 402 handed
      # back untouched (flagged `pow_retried`), where
      # {Scenario#payment_required_stall} turns it into a could-not-test verdict
      # that says the toll was paid and demanded again — rather than spinning
      # the harness or, worse, hiding the second demand behind a third solve.
      #
      # A 402 carrying NO `challenges` is one of the other two 402s
      # (`payment_setup_required` / `payment_failed`): nothing to solve, so the
      # answer is returned unchanged and stalls exactly as it did before.
      #
      # `/kiosk/agents/kyc` deliberately has no retry: {PowGate} is called only
      # from the wire verbs and from registration, so that endpoint cannot
      # answer `pow_required` — a 402 there is a payment 402 and paying a PoW
      # toll would not be what it asked for.
      #
      # @param response [Response] the provider's first answer
      # @yieldparam pow [String] raw `Kiosk-PoW` header value (JSON array of proofs)
      # @yieldreturn [Response] the answer to the re-sent request
      # @return [Response] the retried answer, or +response+ when there is
      #   nothing to solve
      def with_pow_retry(response)
        return response unless response.status == 402

        # RFC 9457: `challenges` is a TOP-LEVEL extension member of the problem
        # document, not a field of a nested `error` object.
        challenges = response.body.is_a?(Hash) ? response.body["challenges"] : nil
        return response unless challenges.is_a?(Array) && challenges.any?

        proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
        yield(JSON.generate(proofs)).with(pow_retried: true)
      end

      # Fetch a challenge for +pem+ and sign it with the private +key+ — the
      # client side of the PoP handshake. `aud` binds the proof to the origin we
      # dialed so it can't be relayed to another provider.
      def build_pop(key, pem)
        resp  = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
        nonce = resp.body.is_a?(Hash) ? resp.body["challenge"] : nil
        JWT.encode(
          { aud: @base_url, nonce: nonce, jti: SecureRandom.uuid, iat: Time.now.to_i },
          key, "RS256",
        )
      end

      # Solve one Equihash registration challenge with the reference Python
      # solver that ships inside kiosk-pow-equihash, located via that gem's
      # public accessor — so it resolves from an installed gem, not only in a
      # monorepo checkout. Registration PoW is the SAME Equihash machinery as
      # the query/run gate (one PoW backend: Equihash).
      #
      # @param challenge [Hash] a challenge from the 402 error.challenges[]
      # @return [Hash] the proof nonce {"indices"=>[...], "header_nonce"=>N}
      def equihash_solve(challenge)
        out, status = Open3.capture2("python3", Kiosk::Pow::Equihash.solver_path, JSON.generate(challenge))
        raise "equihash solve.py failed: #{out}" unless status.success?
        parsed = JSON.parse(out)
        raise "equihash solve.py error: #{parsed["error"]}" if parsed.key?("error")
        { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
      end

      # POST JSON to the given path; returns a {Response}.
      #
      # @param path   [String]      URL path (including leading slash)
      # @param body   [Hash]        request body (serialised to JSON)
      # @param bearer [String, nil] Bearer token for Authorization header
      # @param pow    [String, nil] raw Kiosk-PoW header value (the proof(s) as
      #   raw JSON, ADR-0022) — used by the register + wire-verb PoW retries
      # @return [Response]
      def post_json(path, body, bearer: nil, pow: nil)
        uri = URI("#{@base_url}#{path}")
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{bearer}" if bearer
        headers["Kiosk-PoW"] = pow if pow

        req = Net::HTTP::Post.new(uri, headers)
        req.body = JSON.generate(body)

        http = Net::HTTP.new(uri.host, uri.port)
        res  = http.request(req)

        parsed = begin
          JSON.parse(res.body)
        rescue JSON::ParserError
          {}
        end

        Response.new(status: res.code.to_i, body: parsed)
      end

      # GET the given path; returns a {Response}. Used for the auth-challenge
      # fetch that opens the registration handshake AND, since 0.4, for every
      # query — a query's arguments are the query string.
      #
      # @param path   [String]      URL path (including leading slash)
      # @param params [Hash]        query-string parameters
      # @param bearer [String, nil] Bearer token for Authorization header
      # @param pow    [String, nil] raw Kiosk-PoW header value. A GET has no
      #   body, so the header is the ONLY channel a proof can travel on — which
      #   is why ADR-0022 moved it there before the wire needed it. {#query} now
      #   passes it, on the one bounded retry {#with_pow_retry} performs (K-760):
      #   a toll DEFERS a request rather than refusing it (K-736), and a
      #   deferred attack that is never re-sent is an attack that was never run.
      def get_json(path, params: {}, bearer: nil, pow: nil)
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) unless params.nil? || params.empty?
        headers = {}
        headers["Authorization"] = "Bearer #{bearer}" if bearer
        headers["Kiosk-PoW"] = pow if pow
        res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))

        parsed = begin
          JSON.parse(res.body)
        rescue JSON::ParserError
          {}
        end

        Response.new(status: res.code.to_i, body: parsed)
      end
    end
  end
end
