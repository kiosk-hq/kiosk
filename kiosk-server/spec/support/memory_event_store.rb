# frozen_string_literal: true

# A DB-free event store with the shipped store's contract. The shipped default
# is the database table (event_stores_spec).
class MemoryEventStore
  def initialize
    @mutex  = Mutex.new
    @seq    = 0
    @by_key = Hash.new { |hash, key| hash[key] = [] }
  end

  def append(identity_key, event)
    @mutex.synchronize do
      @seq += 1
      @by_key[identity_key.to_s] << event.merge('id' => @seq).freeze
      @seq
    end
  end

  def since(identity_key, id)
    @mutex.synchronize { @by_key[identity_key.to_s].select { |event| event['id'] > id.to_i } }
  end

  def head = @mutex.synchronize { @seq }

  def truncated?(_identity_key, _id) = false
end
