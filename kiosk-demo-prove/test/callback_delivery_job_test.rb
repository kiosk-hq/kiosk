# frozen_string_literal: true

require 'test_helper'

class CallbackDeliveryJobTest < ActiveJob::TestCase
  ARGS = { callback_url: 'http://127.0.0.1:3004/kyc/callback', request_id: 'r-1', kyc_jws: 'a.b.c', nonce: 'n-1' }.freeze

  # Runs the job with the callback answering `statuses` in turn; returns the posts it made.
  def deliver_answering(*statuses)
    posts = []
    answer = lambda do |**args|
      posts << args
      statuses.shift
    end
    CallbackPoster.stub(:deliver, answer) { yield }
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
