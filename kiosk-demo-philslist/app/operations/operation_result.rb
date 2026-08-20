# frozen_string_literal: true

# WHAT A philslist WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half of this object lives in the gem: {Kiosk::OperationResult} in
# kiosk-server holds the constructor and the ok/refused/status trio, and every
# demo subclasses it. It was hand-copied into all seven demos until K-792 and
# T-089 promoted it — the part that repeated had no per-app decision in it,
# and `:per_demo` in bin/check-demo-copies meant nothing compared the copies.
# What stays here is the part that DOES carry a decision: the STATUSES map.
#
# philslist has no second (human) surface for these verbs — its public board is
# read-only, and the owner-scoped EDIT authority is deliberately wire-only. The
# seam is still the right shape and not speculation: `post_listing`'s three
# guards and the two owner-scoped UPDATEs are business decisions, and a `render`
# in the middle of them is the thing every T-057 slice had to reason about. It is
# also what lets `edit_listing` and `close_listing` share ONE copy of the shape
# guard and the ownership sentence (see {ListingAccess}) — two copies of an
# access refusal is two chances for one of them to drift.
class OperationResult < Kiosk::OperationResult
  # The two codes philslist's writes refuse with, and the Rails status symbol
  # each renders as. Deliberately NOT the full fourteen-code wire vocabulary: a
  # code this app never produces has no business having a mapping here, and
  # `fetch` turning a typo into a loud KeyError is the point of writing it out.
  # philslist's two are the two its handlers rendered before the conversion —
  # `bad_request` (an unknown category_slug, a missing title/body, a malformed
  # listing_id) and `forbidden` (an owner-scoped UPDATE that touched no row).
  # There is no `not_found` and there must not be: a listing that does not exist
  # and one that belongs to somebody else answer the SAME 403, so cross-owner
  # probing cannot enumerate which ids exist.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze
end
