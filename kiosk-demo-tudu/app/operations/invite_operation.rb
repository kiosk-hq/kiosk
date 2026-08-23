# frozen_string_literal: true

# Required here, where the code is minted, rather than in an initializer.
require "base64"
require "securerandom"

# invite — OWNER-ONLY. Mint a single-use, TTL'd collaboration code; store ONLY
# its SHA-256 digest; hand the plaintext back ONCE. The code travels
# human-to-human; the recipient's agent redeems it with accept_invite. Reached
# from the wire and from the web UI's "Invite a collaborator" button, which shows
# the plaintext in a flash — the one place a human sees it.
class InviteOperation
  # 10 minutes. A business rule, so it lives with the operation that sets it
  # rather than on the Invite model, which only knows how to hash.
  TTL_SECONDS = 600

  def self.call(principal_id:, list_id:)
    refusal = ListAccess.check(list_id, require_owner: true)
    return refusal if refusal

    # A device_code-grade secret: 256 bits of entropy, base64url. Only the digest
    # is persisted (the kiosk-server LinkCode hygiene, adapted).
    code = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)

    # `expires_at` is written on the APP clock, and so is the comparison that
    # reads it in {AcceptInviteOperation}: one clock on both ends, so no skew
    # between the app and Postgres can shorten or extend the TTL.
    Invite.insert!(
      { list_id:               list_id,
        code_digest:           Invite.digest(code),
        created_by_account_id: principal_id,
        expires_at:            TTL_SECONDS.seconds.from_now },
    )

    OperationResult.ok({ "code" => code, "expires_in" => TTL_SECONDS })
  end
end
