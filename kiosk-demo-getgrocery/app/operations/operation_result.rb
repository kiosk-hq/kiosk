# frozen_string_literal: true

# What a getgrocery write Operation answers — one value, or one refusal.
#
# The shared half lives in the gem: {Kiosk::OperationResult} in kiosk-server
# holds the constructor and the ok/refused/status trio. What stays here is the
# part that carries a per-app decision: the STATUSES map.
class OperationResult < Kiosk::OperationResult
  # The codes getgrocery's verbs refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out.
  # `kyc_required` and `forbidden` are BOTH 403, so the code is not derivable
  # from the status: it is the only thing that tells an assistant "go and get
  # attested" apart from "this is not yours". `quota_exceeded` (the
  # per-principal cap on outstanding broker intakes) is the one refusal here
  # that means "come back later" rather than "no": 429 is the status §9 gives
  # it, and the only one an assistant can read as temporary without parsing
  # prose.
  STATUSES = {
    "bad_request"    => :bad_request,
    "forbidden"      => :forbidden,
    "not_found"      => :not_found,
    "kyc_required"   => :forbidden,
    "quota_exceeded" => :too_many_requests,
  }.freeze
end
