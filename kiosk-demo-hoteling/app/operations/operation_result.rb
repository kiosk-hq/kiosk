# frozen_string_literal: true

# WHAT A hoteling WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half lives in the gem: {Kiosk::OperationResult} holds the
# constructor and the ok/refused/status trio. What stays here is the part that
# carries a per-app decision — the STATUSES map.
class OperationResult < Kiosk::OperationResult
  # The codes hoteling's verbs refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out.
  #
  # `not_found` is here for T-090's three-way rule (spec §9.1): a `property_id`
  # that ADDRESSES a property which does not exist is 404 — `hotel_detail` and
  # `availability` both do — while `search_hotels`' neighbourhood/amenity
  # filters answer `200 []`.
  STATUSES = {
    "bad_request" => :bad_request,
    "forbidden"   => :forbidden,
    "conflict"    => :conflict,
    "not_found"   => :not_found,
  }.freeze
end
