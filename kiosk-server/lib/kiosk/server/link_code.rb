# frozen_string_literal: true

module Kiosk
  module Server
    # The link half of the account-binding ceremony — the
    # human-initiated direction, a Kiosk EXTENSION (auth.md defines no
    # reverse flow): the signed-in account holder mints a short-lived,
    # single-use link code from the provider's web UI, hands it to their
    # assistant (pastes into chat), and the assistant redeems it together
    # with its public key and a possession proof.
    #
    #   .mint   — POST /auth/link handler logic: creates a PRE-APPROVED
    #             `:link` row already bound to the holder's user_id.
    #   .redeem — POST /auth/claim handler logic: proves key possession
    #             (BIND-POP), then binds via {AccountBinding.bind!} with
    #             the same fresh/rebind semantics as the claim flow.
    #
    # Mirror-image of {DeviceCodeGrant}: the code travels human→agent
    # instead of agent→human, so the strong secret (a device_code-grade
    # 256-bit token — no short typed code is involved) is what the human
    # hands over. Only its hash is stored; the row is single-use and TTL'd.
    module LinkCode
      # `client_id` recorded on link rows — the "initiating client" of this
      # direction is the provider's own link page, not an OAuth client.
      CLIENT_ID = "kiosk-link"

      module_function

      # Mint a link code for the signed-in account holder. The row is born
      # `:approved` with `user_id` already stamped — the human IS the
      # approval; no verify step follows.
      #
      # `requested_role:` IS A MISNOMER HERE AND EVERYWHERE (K-1126): nothing
      # requests it. On a `:link` row it is the MINTING human's own role, read
      # off their session by the caller ({AuthController#link},
      # {AssistantsController#link}, both passing `Identity#role`) — the
      # assistant that later redeems the code supplies nothing and cannot.
      # Read it as `approved_role`; {DeviceAuthorization} records why the
      # column keeps the name.
      #
      # @return [Hash] {link_code:, expires_in:, da:}
      def mint(user_id:,
               requested_role: nil,
               store: Kiosk.configuration.device_authorization_store,
               expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
               now: Time.now)
        plain_device_code, _plain_user_code, da = DeviceAuthorization.generate(
          client_id:      CLIENT_ID,
          kind:           :link,
          requested_role: requested_role,
          expires_in:     expires_in,
          now:            now,
        )
        da = da.approve(user_id: user_id)
        store.create(da)

        { link_code: plain_device_code, expires_in: expires_in, da: da }
      end

      # Redeem a link code with a public key and a register-shaped
      # possession proof (BIND-POP). Order matters: the proof is verified
      # BEFORE the row is consumed — a failed proof leaves the code live so
      # the rightful key holder can retry.
      #
      # @return [Hash] {agent_id:, user_id:, access_token:} — same shape as
      #   POST /auth/register (201).
      # @raise [Errors::NotFound]        unknown, expired, or non-link code
      # @raise [Errors::Conflict]        code already redeemed
      # @raise [Errors::BadRequest]      malformed/undersized public key
      # @raise [Errors::Unauthenticated] failed possession proof
      def redeem(code:, public_key_pem:, signed:,
                 store: Kiosk.configuration.device_authorization_store,
                 now: Time.now)
        raise Errors::BadRequest.new("code required") if code.nil? || code.to_s.empty?

        # Same normalisation + key floor as registration
        # (PopVerifier's checks are THE key checks).
        pem = public_key_pem.to_s.strip
        PopVerifier.load_public_key(pem)

        da = store.find_by_device_code_hash(DeviceAuthorization.hash_device_code(code.to_s))
        if da.nil? || !da.link?
          raise Errors::NotFound.new(
            "unknown link code",
            hint: "the account holder mints one at POST /auth/link (link codes are single-use and short-lived)",
          )
        end
        raise Errors::Conflict.new("link code already used") if da.consumed?

        if da.expired_at_time?(now) && da.approved?
          store.update(da.expire)
          raise Errors::NotFound.new("link code expired")
        end
        raise Errors::NotFound.new("link code expired") if da.expired?

        # BIND-POP: prove possession of the presented key BEFORE binding.
        # Raises Unauthenticated on any proof failure; the code stays live.
        payload = PopVerifier.verify!(public_key_pem: pem, signed: signed)
        AuthChallenge.consume!(public_key_pem: pem, nonce: payload.fetch(:nonce))

        # SINGLE-USE IS DECIDED BY THE ROW, NOT BY THE `consumed?` CHECK ABOVE
        # (K-887). That check is read off the snapshot taken at
        # `find_by_device_code_hash`, so on its own it lets two concurrent
        # redemptions of ONE code -- with two DIFFERENT public keys -- both
        # reach the bind and both attach an assistant to the human's account.
        # The claim is an atomic conditional consume; the loser gets the same
        # `409` a serial second redemption gets, which is the signal that tells
        # the human their code leaked.
        #
        # It runs AFTER the proof and BEFORE the bind, and both halves of that
        # placement are deliberate: after, because a failed proof must leave
        # the code live for the rightful key holder to retry (the check above
        # stays as the cheap early answer for the ordinary already-used case);
        # before, because a bind that races another bind is the harm.
        claimed = store.claim_consume(da, now: now)
        raise Errors::Conflict.new("link code already used") if claimed.nil?

        # `requested_role:` carries what was stamped at MINT, from the human's
        # own session — never anything the redeeming assistant sent, which is
        # why the name is a misnomer kept only for the column (K-1126).
        result = AccountBinding.bind!(
          public_key_pem: pem,
          user_id:        da.user_id,
          requested_role: da.requested_role,
        )

        { agent_id: result[:agent_id], user_id: result[:user_id], access_token: result[:access_token] }
      end
    end
  end
end
