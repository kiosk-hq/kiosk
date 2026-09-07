# frozen_string_literal: true

# ONE named anonymized boolean a valid KYC attestation granted an agent, in the
# ENGINE's own `kiosk.kyc_attributes` table. For skooti that is `age_over_18`
# and `licence_a`, and `rent_motorcycle`'s Gate 0 needs BOTH — the combustion
# motorcycle is this origin's only KYC-gated vehicle; the licence-free scooter
# is ungated on purpose.
#
# An engine-owned table with no engine-owned reader, the {Agent} / {Settlement}
# shape: kiosk-server writes these rows (POST /agents/kyc, one per name the
# attestation granted, replacing whatever was there) and skooti only ever reads
# them, through {Agent.kyc_granted?}.
#
# There is no VALUE column, and the gate depends on that. A map of grants would
# have to carry a value, and a value has spellings — JSON `true`, the string
# `"true"`, `1` — so every reader would have to decide which ones count, and a
# reader that decided differently would be a KYC gate disagreeing with the
# engine about a boolean. The grant IS the row: present means granted, absent
# means not, and the only place a spelling is judged is the engine's write.
# Only the NAMES are ever stored — never the DOB, licence number, or any
# document (the anonymized property ADR-0020 exists for).
class KycAttribute < ApplicationRecord
  self.table_name = "kiosk.kyc_attributes"

  belongs_to :agent, inverse_of: :kyc_attributes
end
