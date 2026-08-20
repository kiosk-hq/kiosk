# frozen_string_literal: true

# WHAT A hoteling WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half of this object lives in the gem: {Kiosk::OperationResult} in
# kiosk-server holds the constructor and the ok/refused/status trio, and every
# demo subclasses it. It was hand-copied into all seven demos until K-792 and
# T-089 promoted it — the part that repeated had no per-app decision in it,
# and `:per_demo` in bin/check-demo-copies meant nothing compared the copies.
# What stays here is the part that DOES carry a decision: the STATUSES map.
#
# hoteling has no second (human) surface today — its web page is read-only
# counts — so unlike tudu there is no web controller sharing these Operations.
# The seam is still the right shape and not speculation: it is what keeps
# `reserve_room`'s three-part inventory guard and `confirm_booking`'s two gates
# out of a controller, where a `render` in the middle of a transaction is what
# every one of the earlier slices had to reason about.
class OperationResult < Kiosk::OperationResult
  # The codes hoteling's verbs refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out. tudu's
  # copy lists two; hoteling's FOUR are the four its handlers actually raise.
  #
  # `not_found` IS ONE OF THEM, and the two edits that removed and restored it
  # are worth stating together because they are about different things. K-794
  # gave `hotel_detail` an ARRAY response shape and, in the same move, made an
  # unknown `property_id` answer the EMPTY array — nothing refused `not_found`
  # any more, so this table stopped mapping it. T-090's three-way rule (Phil,
  # 2026-08-19; spec §9.1) separates the two: the ARRAY SHAPE STAYS, and an id
  # that ADDRESSES a property which does not exist is `404 not_found` again,
  # because an empty list would assert the property exists and merely has no
  # rows. Two verbs take `property_id` and they answer it differently on
  # purpose — `hotel_detail` ADDRESSES a property, `availability` also
  # addresses one before filtering its room types, so both 404; the
  # `neighbourhood`/`amenity` filters of `search_hotels` stay `200 []`.
  STATUSES = {
    "bad_request" => :bad_request,
    "forbidden"   => :forbidden,
    "conflict"    => :conflict,
    "not_found"   => :not_found,
  }.freeze
end
