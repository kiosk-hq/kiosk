# frozen_string_literal: true

RSpec.describe 'the be_rls_denied matcher' do
  it 'passes when the block raises RLSDenied' do
    expect do
      raise Kiosk::TestHelpers::Errors::RLSDenied
    end.to be_rls_denied
  end

  it 'fails when the block raises nothing' do
    expect do
      expect { nil }.to be_rls_denied
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /didn't/)
  end

  it 'fails with a clear message when the block raises a different error' do
    expect do
      expect { raise ArgumentError, 'wrong' }.to be_rls_denied
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /raised ArgumentError/)
  end

  it 'negation passes when the block raises something else' do
    expect { raise 'boom' }.not_to be_rls_denied
  end

  it 'negation passes when the block raises nothing' do
    expect { 1 + 1 }.not_to be_rls_denied
  end
end

RSpec.describe 'the be_quota_exceeded matcher' do
  it 'passes when the block raises QuotaExceeded' do
    expect do
      raise Kiosk::TestHelpers::Errors::QuotaExceeded
    end.to be_quota_exceeded
  end

  it 'fails when the block raises RLSDenied (different error)' do
    expect do
      expect { raise Kiosk::TestHelpers::Errors::RLSDenied }.to be_quota_exceeded
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /RLSDenied/)
  end

  it 'negation passes when no quota error' do
    expect { 1 + 1 }.not_to be_quota_exceeded
  end
end

RSpec.describe 'Kiosk RSpec matchers end-to-end with NullExecutor' do
  it 'be_rls_denied catches an error enqueued on the executor' do
    executor = Kiosk::TestHelpers.executor
    executor.enqueue_error(:query, :rls_denied)
    expect { executor.query('select 1') }.to be_rls_denied
  end

  it 'be_quota_exceeded catches an enqueued quota error' do
    executor = Kiosk::TestHelpers.executor
    executor.enqueue_error(:run_action, :quota_exceeded)
    expect { executor.run_action(:x, {}) }.to be_quota_exceeded
  end
end
