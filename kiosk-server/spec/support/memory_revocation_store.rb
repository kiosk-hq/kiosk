# frozen_string_literal: true

# A DB-free revocation store with the shipped store's contract. The shipped
# default is the database table (revocation_stores_spec).
class MemoryRevocationStore
  def initialize
    @watermarks = {}
    @mutex      = Mutex.new
  end

  def revoke_all(agent_id, at:)
    return if agent_id.nil?

    @mutex.synchronize { @watermarks[agent_id] = [@watermarks[agent_id].to_i, at.to_i].max }
  end

  def watermark_for(agent_id) = @mutex.synchronize { @watermarks[agent_id] }

  def revoked?(agent_id:, iat:)
    watermark = watermark_for(agent_id)
    !watermark.nil? && !iat.nil? && iat.to_i < watermark
  end
end
