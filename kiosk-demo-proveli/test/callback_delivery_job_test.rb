# frozen_string_literal: true

require 'test_helper'

class CallbackDeliveryJobTest < ActiveJob::TestCase
  ARGS = { callback_url: 'http://127.0.0.1:3004/kyc/callback', request_id: 'r-1', kyc_jws: 'a.b.c', nonce: 'n-1' }.freeze

  # Runs the job with the callback answering `statuses` in turn; returns the posts it made.
  def deliver_answering(*statuses, &)
    posts = []
    answer = lambda do |**args|
      posts << args
      statuses.shift
    end
    CallbackPoster.stub(:deliver, answer, &)
    posts
  end

  test 'sends the attestation again after a callback that does not answer' do
    posts = deliver_answering(nil, 200) { perform_enqueued_jobs { CallbackDeliveryJob.perform_later(**ARGS) } }

    assert_equal [ARGS, ARGS], posts
  end

  test 'sends the attestation again after a callback that answers 5xx' do
    posts = deliver_answering(503, 200) { perform_enqueued_jobs { CallbackDeliveryJob.perform_later(**ARGS) } }

    assert_equal 2, posts.size
  end

  # :polynomially_longer waits executions**4 + 2 seconds, plus up to 15 % jitter.
  test 'waits longer before each attempt' do
    waits = []
    deliver_answering(nil, nil) do
      freeze_time do
        CallbackDeliveryJob.perform_now(**ARGS)
        waits << (enqueued_jobs.last[:at] - Time.now.to_f)
        CallbackDeliveryJob.deserialize(enqueued_jobs.last).perform_now
        waits << (enqueued_jobs.last[:at] - Time.now.to_f)
      end
    end

    assert_in_delta 3.15, waits.first, 0.2
    assert_in_delta 19.2, waits.last, 1.3
  end

  # perform_enqueued_jobs reports the job's last error wrapped in Minitest::UnexpectedError.
  test "stops after Rails' default five attempts" do
    error = nil
    posts = deliver_answering(*[nil] * 6) do
      error = assert_raises(Minitest::UnexpectedError) do
        perform_enqueued_jobs { CallbackDeliveryJob.perform_later(**ARGS) }
      end
    end

    assert_kind_of CallbackDeliveryJob::NotAccepted, error.error
    assert_equal 5, posts.size
  end
end
