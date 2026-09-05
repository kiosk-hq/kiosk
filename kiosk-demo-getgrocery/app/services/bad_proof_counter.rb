# frozen_string_literal: true

require "sqlite3"

# The demo's PER-IDENTITY bad-proof tally.
#
# The engine calls `on_bad_proof` with the verified agent identity every time a
# cryptographically invalid PoW proof arrives; this counts those rejections per
# identity (keyed by the agent credential id) in a small sqlite database, so one
# abusive assistant's bad proofs cannot inflate anyone else's count. sqlite's
# single-writer lock also stops concurrent server processes fighting over one
# read-modify-write cycle.
#
# ⚠ STILL A TOY in two labelled ways — fine for a demo, wrong for production:
#   · TRUNCATED AT BOOT — reset! wipes the table, so a redeploy zeroes every
#     accumulated signal;
#   · NO TTL / DECAY — within one boot the count only grows, where a real signal
#     decays over a window so an identity is not condemned forever.
# A production counter keeps the per-identity keying and adds decay plus
# durability.
#
# Consumers: the demo initializer (reset! at boot, increment on rejection) and
# script/pow_flow.rb (count, to assert the server counted what the flow sent).
module BadProofCounter
  module_function

  # Wipe the store at boot: the demo flows assert exact counts, so every boot
  # starts from zero.
  def reset!(path)
    with_db(path) { |db| db.execute("DELETE FROM bad_proofs") }
  end

  # Record one rejected proof for this identity (atomic upsert — safe under
  # concurrent writers thanks to sqlite's write lock + busy_timeout).
  def increment(path, identity_key)
    with_db(path) do |db|
      db.execute(<<~SQL, [identity_key.to_s])
        INSERT INTO bad_proofs (identity, count) VALUES (?, 1)
        ON CONFLICT(identity) DO UPDATE SET count = count + 1
      SQL
    end
  end

  # This identity's tally; 0 when it has never submitted a bad proof.
  def count(path, identity_key)
    with_db(path) do |db|
      db.get_first_value("SELECT count FROM bad_proofs WHERE identity = ?", [identity_key.to_s]).to_i
    end
  end

  # One short-lived connection per call: the writers are Rails request threads
  # and the reader is a separate driver process, so nothing shares a handle.
  # busy_timeout makes a concurrent writer wait (up to 5s) instead of raising
  # SQLite3::BusyException.
  def with_db(path)
    db = SQLite3::Database.new(path)
    db.busy_timeout = 5_000
    db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS bad_proofs (
        identity TEXT PRIMARY KEY,
        count    INTEGER NOT NULL
      )
    SQL
    yield db
  ensure
    db&.close
  end
end
