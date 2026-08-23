# frozen_string_literal: true

require "digest"

# The account principal: ONE table for both human account holders and headless
# assistant-created principals — no separate "user" surface. The
# physical table stays `users` so the framework identity wiring matches every
# other demo; the "account" in the design doc is this row.
# `kiosk.current_user_id()` resolves to this table's `id`.
#
# Human account holders sign in with email + password (the Devise session that
# approves assistant links on the verify page). Assistant accounts are rows in
# this same table WITHOUT credentials — created by the `config.assistant_creation`
# factory when an agent registers headless; kiosk-pop key possession is their
# only channel, so they can never drive the human surfaces. On account-link the
# rebind hook migrates a headless account's lists/memberships to the human.
class User < ApplicationRecord
  # :registerable lets a visitor create their own account (sign-up), so the
  # human↔assistant link flow is walkable end-to-end without a seeded login.
  # A fresh row is a valid account principal on its own (kiosk.current_user_id()
  # resolves to this table's id), so self-registration needs no extra wiring.
  devise :database_authenticatable, :registerable

  # Lists this account OWNS (as the owner principal). account_id is the
  # re-parent target of the assistant_claimed rebind hook.
  has_many :lists, foreign_key: :account_id, inverse_of: :account, dependent: :destroy
  # Every list this account can reach — the membership-based access surface.
  has_many :memberships, foreign_key: :account_id, inverse_of: :account, dependent: :destroy

  # THE ONE NAME THIS ACCOUNT HAS IN FRONT OF OTHER PEOPLE (K-950).
  #
  # `list_members` publishes a row PER MEMBER of a shared list, and until K-950
  # the column it published was `users.email` — so every housemate on a list
  # learned the login address of every other housemate, and the demo's own web
  # board published a masked local-part (`al•••`) of the same column, which
  # against a known domain is barely a mask at all. Membership is consented (an
  # owner minted a single-use invite and a human redeemed it), which made this
  # far weaker than philslist's ungated board — but consent to share a list is
  # not consent to publish an email address, and Phil's rule is categorical: no
  # authorization model justifies putting a login credential on the wire. The
  # spec now says so at every `reach`, not only at `published` (Section 7.2).
  #
  # SO: the account's OWN chosen name, and an opaque pseudonym when it has none.
  #
  # WHY A NAME AT ALL, where philslist publishes only `seller-<hex>`. The two
  # audiences are different and the difference is the whole design. philslist's
  # board is read by strangers, so an opaque handle costs a buyer nothing. A
  # tudu roster is read by the people the account holder DELIBERATELY invited
  # into their household list — "who added the tent?" is the question the verb
  # exists to answer, and `member-4f2a9c1e3b7d` does not answer it. A name the
  # reader recognises is the point.
  #
  # WHY THE FALLBACK IS DERIVED FROM THE ACCOUNT UUID AND NEVER FROM THE
  # ADDRESS — this is K-913's argument and it transfers unchanged. Hashing an
  # email is reversible in practice: the input space is a wordlist, and anyone
  # holding a candidate address confirms it with one hexdigest. A v4 UUID is 122
  # bits of randomness that appears nowhere a reader can enumerate, so the same
  # construction over it inverts to nothing. Masking the local part is NOT an
  # acceptable third option: two characters plus the confirmation that an
  # address holds an account here is a disclosure, not a redaction.
  #
  # 48 bits (12 hex), deterministic and unsalted, for philslist's reasons: a
  # display label is never an argument to a verb (`remove_member` takes
  # `account_id`), nothing rests on it being unique, and stability across boots
  # and reseeds is what lets the redteam battery assert on it.
  #
  # @param display_name [String, nil] the account's chosen name, or nil/blank
  # @param account_id [String] users.id — the uuid, NOT the address
  # @return [String] never nil, never an address
  def self.public_name(display_name, account_id)
    chosen = display_name.to_s.strip
    return chosen unless chosen.empty?

    "member-#{Digest::SHA256.hexdigest(account_id.to_s)[0, 12]}"
  end

  # Instance form, for callers that already hold the record.
  def public_name
    self.class.public_name(display_name, id)
  end
end
