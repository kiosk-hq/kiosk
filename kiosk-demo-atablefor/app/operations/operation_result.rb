# frozen_string_literal: true

# WHAT AN atablefor WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half lives in the gem: {Kiosk::OperationResult} in kiosk-server
# holds the constructor and the ok/refused/status trio, and every demo
# subclasses it. What stays here is the part that carries a per-app decision:
# the STATUSES map.
class OperationResult < Kiosk::OperationResult
  # The three codes atablefor's writes refuse with, and the Rails status symbol
  # each renders as. Deliberately NOT the full fourteen-code wire vocabulary: a
  # code this app never produces has no business having a mapping here, and
  # `fetch` turning a typo into a loud KeyError is the point of writing it out.
  # There is no `not_found` and there must not be: "no such booking", "not
  # yours" and "already cancelled" are ONE answer, so probing cannot enumerate
  # other principals' booking ids.
  STATUSES = {
    "bad_request" => :bad_request,
    "conflict"    => :conflict,
    "forbidden"   => :forbidden,
  }.freeze
end
