# frozen_string_literal: true

require "digest"

# The account principal: ONE table for both human account holders
# and headless assistant-created principals — no separate "user" surface.
# `kiosk.current_user_id()` resolves to this table's `id` (the physical table
# stays `users` so the framework identity wiring matches every other demo;
# "account" throughout this demo means this row).
#
# Human account holders sign in with email + password (the Devise session that
# approves assistant links on the verify page). Assistant accounts are rows in
# this same table WITHOUT credentials — kiosk-pop key possession is their only
# channel, so they can never drive the human surfaces.
class User < ApplicationRecord
  devise :database_authenticatable

  # Listings this account owns (as seller). owner_id is the load-bearing
  # isolation predicate for edit/close (see config/initializers/kiosk.rb).
  has_many :listings, foreign_key: :owner_id, inverse_of: :owner, dependent: :destroy

  # THE ONE PUBLIC NAME AN ACCOUNT HAS ON THIS BOARD (K-913).
  #
  # The board is deliberately cross-owner: every authenticated principal sees
  # every open listing. Until K-913 the seller column it published was
  # `users.email`, so registering an assistant and calling `browse_listings`
  # returned the address of every account holder in the seed — and the public
  # web board published a masked local-part (`al•••`) of the same column,
  # which against a known domain is barely a mask at all. For a protocol whose
  # pitch is that a human is not tracked across operators, publishing the login
  # identifier of everyone who ever posted was the wrong thing to demonstrate.
  #
  # SO: a pseudonym derived from the account UUID, never from the email.
  # That distinction is the whole security argument. Hashing an email would be
  # reversible in practice — the input space is a wordlist, and anyone holding a
  # candidate address confirms it with one hexdigest. A v4 UUID is 122 bits of
  # randomness that appears nowhere on this board, so the same construction over
  # it is not invertible by anything an attacker can enumerate.
  #
  # PER-SELLER, NOT PER-LISTING, and that is a privacy tradeoff taken with eyes
  # open. A per-listing handle would make one seller's listings mutually
  # unlinkable; a per-seller handle links them. Per-seller wins here for two
  # reasons. First, the linkage is not actually withheld by a per-listing
  # handle — the same seller's listings share wording, price style and often a
  # contact line, so unlinkability would be a promise the board cannot keep, and
  # a promise that cannot be kept is worse than none. Second, "does this seller
  # have other things for sale" is what a classifieds board is FOR, and it is
  # the same property philslist exists to demonstrate: Alice's household binds
  # two assistants to ONE account, so both their listings must read under one
  # seller. A per-listing handle would erase the demo's own headline.
  #
  # 48 bits (12 hex): a board would need on the order of a million accounts
  # before a collision became likely, and no security decision rests on the
  # handle being unique — it is a display label, never an argument to a verb.
  # Deterministic and unsalted on purpose: stable across boots, reseeds and
  # processes, so the redteam battery can assert on it.
  def self.public_handle(account_id)
    "seller-#{Digest::SHA256.hexdigest(account_id.to_s)[0, 12]}"
  end

  # Instance form, for callers that already hold the record.
  def public_handle
    self.class.public_handle(id)
  end
end
