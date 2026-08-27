# frozen_string_literal: true

# prove_requests — one row per verification the broker is asked to run.
# An OPERATOR creates a row at intake (a confirmer CANNOT — the row's
# unguessable request_id is minted here and handed only into the agent→human
# channel). The human's yes/no flips it to confirmed/declined ONCE (single-use);
# an expired row is un-confirmable.
#
#   request_id       — 256-bit unguessable PK; the ONLY credential the
#                      verification_url carries (no sign-in). Not enumerable.
#   operator_id      — the requesting operator (skooti). The minted claim binds
#                      to it (aud/operator); another operator cannot use it.
#   callback_url     — where the broker POSTs the signed claim on approve. It is
#                      validated against the operator's allow-listed host at
#                      intake (SSRF/open-relay guard) — never free-form-honoured.
#   requested_claims — the anonymized claims asked for, e.g.
#                      ["age_over_18","licence_category:A"].
#   subject_handle   — the operator's user_id for the requesting agent; the
#                      minted claim's `sub`, so the operator's KycVerifier binds
#                      it to the SAME agent (cross-subject theft defense).
#   nonce            — echoed in the callback so the operator rejects a stale/
#                      replayed callback.
#   status           — pending → confirmed | declined. Terminal; single-use.
#   expires_at       — TTL; a request past this cannot be confirmed.
#
# This table holds request STATE ONLY (single-use / TTL / no-replay) — never the
# human's identity or their prior answers. Each verification is INDEPENDENT: a
# re-verification (e.g. after an agent reset) starts a fresh row with empty
# checkboxes and the human re-asserts every fact. Deliberate — a "verified-once,
# reuse" store is exactly the account-sharing hole the real (account-to-person)
# check must prevent, so the stub does not model it.
class CreateProveRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :prove_requests, id: false do |t|
      t.string   :request_id,       null: false, primary_key: true
      t.string   :operator_id,      null: false
      t.string   :callback_url,     null: false
      t.jsonb    :requested_claims, null: false, default: []
      t.string   :subject_handle,   null: false
      t.string   :nonce,            null: false
      t.string   :status,           null: false, default: "pending"
      t.datetime :expires_at,       null: false
      t.timestamps
    end
  end
end
