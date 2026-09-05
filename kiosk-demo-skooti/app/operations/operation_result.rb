# frozen_string_literal: true

# WHAT A skooti WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half lives in the gem: {Kiosk::OperationResult} in kiosk-server
# holds the constructor and the ok/refused/status trio, and every demo
# subclasses it. What stays here is the part that carries a decision: the
# STATUSES map.
class OperationResult < Kiosk::OperationResult
  # The codes skooti's verbs refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out.
  # `kyc_required` and `forbidden` are BOTH 403, so the code — not the status —
  # is what tells an assistant "go and get attested" apart from "this is not
  # yours". `quota_exceeded` (K-586) is the per-principal cap on outstanding
  # broker intakes: 429 is the status §9 gives it, and the only refusal on this
  # origin an assistant can read as "come back later" rather than "no".
  # `module_not_served` and `action_failed` are the KYC broker's two absences:
  # 501 when this deployment opens no verifications at all — the
  # same code the engine answers for the submit half of the module — and 500
  # when the broker simply did not complete this request. The 500 is a
  # DELIBERATE refusal rather than an escaped exception, which is the whole
  # difference: it carries a sentence and a hint instead of a Ruby class.
  STATUSES = {
    "bad_request"       => :bad_request,
    "forbidden"         => :forbidden,
    "not_found"         => :not_found,
    "kyc_required"      => :forbidden,
    "quota_exceeded"    => :too_many_requests,
    "action_failed"     => :internal_server_error,
    "module_not_served" => :not_implemented,
  }.freeze
end
