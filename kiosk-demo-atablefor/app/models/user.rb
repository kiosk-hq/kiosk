# frozen_string_literal: true

require "digest"

# The account principal: ONE table for both human diner accounts and headless
# assistant-created principals — no separate "user" surface.
# `kiosk.current_user_id()` resolves to this table's `id`, so a booking made by
# an assistant bound to a human is tied to that human's account.
#
# Human diners sign in with email + password (the Devise session that mints the
# link code approving an assistant). Assistant accounts are rows in this same
# table WITHOUT credentials — kiosk-pop key possession is their only channel, so
# they can never drive the human surfaces.
class User < ApplicationRecord
  devise :database_authenticatable

  has_many :bookings, dependent: :destroy

  # THE ONE PUBLIC NAME AN ACCOUNT HAS ON THE RESERVATIONS BOARD (K-973).
  #
  # The board at `/` and `/reservations` is served to anyone, with no session
  # and no toll, so whatever it prints beside a booking is published. It used
  # to fall back to the login address's local part, masked past two characters
  # (`di•••`) — the same construction philslist published before K-913 and tudu
  # before K-950, and spec §7.2 rule 4 now says outright that masking is not a
  # third option: two characters plus the confirmation that the address holds
  # an account at this origin is a disclosure, not a redaction.
  #
  # SO: the diner's OWN chosen name, and an opaque pseudonym when it has none.
  #
  # THE PSEUDONYM IS DERIVED FROM THE ACCOUNT UUID AND NEVER FROM THE ADDRESS,
  # which is K-913's argument and it transfers unchanged. Hashing an email is
  # reversible in practice: the input space is a wordlist, and anyone holding a
  # candidate address confirms it with one hexdigest. A v4 UUID is 122 bits of
  # randomness that appears nowhere a board reader can enumerate, so the same
  # construction over it inverts to nothing.
  #
  # WHY A HANDLE RATHER THAN ONE FLAT PLACEHOLDER. This board's own sentence is
  # "an assistant's booking shows under its diner's account" — two headless
  # accounts printed identically would make that sentence unreadable, while two
  # distinct handles keep it true without naming anybody. Per-account and not
  # per-booking, for philslist's reason: several assistants bound to ONE diner
  # must read as one diner.
  #
  # 48 bits (12 hex), deterministic and unsalted, also for philslist's reasons:
  # a display label is never an argument to a verb, nothing rests on it being
  # unique, and stability across boots and reseeds is what lets a driver assert
  # on it.
  #
  # @param display_name [String, nil] the diner's chosen name, or nil/blank
  # @param account_id [String] users.id — the uuid, NOT the address
  # @return [String] never nil, never an address
  def self.public_name(display_name, account_id)
    chosen = display_name.to_s.strip
    return chosen unless chosen.empty?

    "diner-#{Digest::SHA256.hexdigest(account_id.to_s)[0, 12]}"
  end

  # Instance form, for callers that already hold the record.
  def public_name
    self.class.public_name(display_name, id)
  end
end
