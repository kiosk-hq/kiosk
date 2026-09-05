# frozen_string_literal: true

# ONE named anonymized boolean a valid KYC attestation granted an agent, in the
# ENGINE's own `kiosk.kyc_attributes` table (canonical migration 006). For
# getgrocery that is `age_over_18`, and nothing else: the alcohol age gate on
# `create_order` is this origin's only KYC-gated verb.
#
# An engine-owned table with no engine-owned reader, the {Agent} / {Settlement}
# shape: kiosk-server writes these rows (POST /agents/kyc, one per name the
# attestation granted, replacing whatever was there) and getgrocery only ever
# reads them, through {Agent.kyc_granted?}.
#
# THERE IS NO VALUE COLUMN, AND THE GATE DEPENDS ON THAT. A jsonb map of
# grants has to carry a value, and a value has spellings — JSON `true`, the
# string `"true"`, `1` — so every reader must decide which ones count, and a
# reader that decides differently is a KYC gate disagreeing with the engine
# about a boolean. The grant IS the row: present means granted, absent means
# not, and the only place a spelling is judged is the engine's write.
# Only the NAMES are ever stored — never the DOB, licence number, or any
# document. That is the anonymized property the whole attestation design
# exists for.
class KycAttribute < ApplicationRecord
  self.table_name = "kiosk.kyc_attributes"

  belongs_to :agent, inverse_of: :kyc_attributes
end
