# frozen_string_literal: true

# Races several real approvals against one committed request.
module ApprovalRace
  HOLD = 0.15

  # Approves `request_id` from `count` threads at once. Every reader is held
  # between its read and its claim, and the winner inside the mint. Returns
  # the HTTP statuses, the statuses the readers saw, and the claims delivered.
  def race_approvals(request_id, count)
    reads = []
    deliveries = []
    mutex = Mutex.new
    holding_reads(reads, mutex) do
      holding_mint do
        collecting_deliveries(deliveries, mutex) { [approve_from_threads(request_id, count), reads, deliveries] }
      end
    end
  end

  private

  def collecting_deliveries(deliveries, mutex, &)
    CallbackPoster.stub(:deliver, ->(**args) { mutex.synchronize { deliveries << args[:kyc_jws] } && 200 }, &)
  end

  def holding_reads(reads, mutex, &)
    find_by = ProveliRequest.method(:find_by)
    read = lambda do |*args, **kwargs|
      row = find_by.call(*args, **kwargs)
      mutex.synchronize { reads << row&.status }
      sleep HOLD
      row
    end
    ProveliRequest.stub(:find_by, read, &)
  end

  def holding_mint(&)
    mint = ProveliKey.method(:mint)
    ProveliKey.stub(:mint, ->(*args) { sleep(HOLD) && mint.call(*args) }, &)
  end

  # Rails draws the routes on the first request, and two first requests at once can fail.
  def warm_up_routes
    ActionDispatch::Integration::Session.new(Rails.application).get('/proveli_key.pem')
  end

  def approve_from_threads(request_id, count)
    warm_up_routes
    threads = Array.new(count) do
      Thread.new do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.post('/verify', params: { request: request_id, decision: 'approve', licence_category: 'A' })
        session.response.status
      end
    end
    threads.map(&:value)
  end
end
