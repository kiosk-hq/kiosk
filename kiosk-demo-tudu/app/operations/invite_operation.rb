# frozen_string_literal: true

require "securerandom"

# A single-use code to share one of the member's own lists, valid for TTL. The
# plaintext code is returned once; only its digest is kept.
class InviteOperation
  TTL = 10.minutes

  def self.call(member_id:, list_id:)
    ListAccess.owner!(list_id)

    code = SecureRandom.urlsafe_base64(32)
    Invite.create!(list_id: list_id, code_digest: Invite.digest(code),
                   created_by_account_id: member_id, expires_at: TTL.from_now)

    code
  end
end
