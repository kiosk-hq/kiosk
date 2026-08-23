# frozen_string_literal: true

# WHAT A philslist WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half lives in the gem: {Kiosk::OperationResult} in kiosk-server
# holds the constructor and the ok/refused/status trio, and every demo
# subclasses it. What stays here is the part carrying a per-app decision: the
# STATUSES map. philslist's writes are wire-only — its public board is read-only
# — and the seam is what lets `edit_listing` and `close_listing` share ONE copy
# of the shape guard and the ownership sentence (see {ListingAccess}).
class OperationResult < Kiosk::OperationResult
  # The two codes philslist's writes refuse with, and the Rails status symbol
  # each renders as. Deliberately NOT the full fourteen-code wire vocabulary: a
  # code this app never produces has no business having a mapping, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out. There is
  # no `not_found` and must not be — a listing that does not exist and one that
  # belongs to somebody else answer the SAME 403, so cross-owner probing cannot
  # enumerate which ids exist.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze
end
