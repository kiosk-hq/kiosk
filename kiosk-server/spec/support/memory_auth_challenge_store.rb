# frozen_string_literal: true

# A DB-free auth challenge store with the shipped store's contract. The shipped
# default is the database table (auth_challenge_stores_spec).
class MemoryAuthChallengeStore
  def initialize
    @store = {}
    @mutex = Mutex.new
  end

  def put(public_key_pem, nonce, exp)
    @mutex.synchronize { @store[public_key_pem] = [nonce, exp] }
  end

  def take(public_key_pem, nonce)
    @mutex.synchronize do
      got_nonce, exp = @store[public_key_pem]
      next false if exp.nil? || exp <= Time.now.to_i || got_nonce != nonce

      @store.delete(public_key_pem)
      true
    end
  end
end
