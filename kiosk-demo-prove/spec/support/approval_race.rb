# frozen_string_literal: true

# Helpers that race several real approvals against one committed request.
module ApprovalRace
  # Holds every reader between its read and its claim. Returns the statuses the readers saw.
  def hold_every_read
    reads = []
    mutex = Mutex.new
    allow(ProveRequest).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
      row = original.call(*args, **kwargs)
      mutex.synchronize { reads << row&.status }
      sleep 0.15
      row
    end
    reads
  end

  # Holds the winner inside the mint, so a second mint would overlap the first.
  def slow_down_mint
    allow(ProveKey).to receive(:mint).and_wrap_original do |original, *args|
      sleep 0.15
      original.call(*args)
    end
  end

  # Stubs the callback. Returns the claims it receives.
  def capture_deliveries
    deliveries = []
    mutex = Mutex.new
    allow(CallbackPoster).to receive(:deliver) do |**kwargs|
      mutex.synchronize { deliveries << kwargs[:kyc_jws] }
      200
    end
    deliveries
  end

  # Rails draws the routes on the first request, and two first requests at once can fail.
  def warm_up_routes
    ActionDispatch::Integration::Session.new(Rails.application).get('/prove_key.pem')
  end

  # Approves one request from `count` threads at once. Returns their HTTP statuses.
  def race_approvals(request_id, count)
    threads = Array.new(count) do
      Thread.new do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.post('/verify', params: { request: request_id, decision: 'approve' })
        session.response.status
      end
    end
    threads.map(&:value)
  end
end

RSpec.configure { |config| config.include ApprovalRace, type: :request }
