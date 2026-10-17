# frozen_string_literal: true

# Calls into Kiosk::Reputation::Challenge with the fixture's fields, any of
# them replaced.
module ChallengeCalls
  def issue_challenge(**overrides)
    fields = { alg:, params:, request_fingerprint: fingerprint, secret:, ttl:, now:, salt:, id: }
    described_class.issue(**fields, **overrides)
  end

  # `.verify` of `challenge` one second after it was issued.
  def verify_challenge(**overrides)
    arguments = { challenge:, nonce: 'good', request_fingerprint: fingerprint, secret:, now: now + 1 }
    described_class.verify(**arguments, **overrides)
  end

  # A backend that raises when called: the cheap checks must answer first.
  def register_spy_backend
    Kiosk::Reputation::Backends.reset!
    Kiosk::Reputation::Backends.register('equihash', TestHelpers::SpyRaisingBackend)
  end
end

# Deterministic fields, so no example depends on random state.
RSpec.shared_context 'with a challenge fixture' do
  include ChallengeCalls

  let(:secret)      { 'test-hmac-secret' }
  let(:fingerprint) { 'fp:sha256:abc123' }
  let(:salt)        { 'A' * 16 } # 16 raw bytes (ASCII)
  let(:id)          { 'challenge-uuid-001' }
  let(:now)         { 1_750_000_000 }
  let(:ttl)         { 300 }
  let(:params)      { { n: 168, k: 7 } }
  let(:alg)         { 'equihash' }
  let(:challenge)   { issue_challenge }

  before { Kiosk::Reputation::Backends.register('equihash', TestHelpers::StubBackend) }
end

RSpec.describe Kiosk::Reputation::Challenge, '.issue' do
  include_context 'with a challenge fixture'

  it 'returns a hash with all required wire fields' do
    expect(challenge).to include(:id, :alg, :params, :salt, :exp, :sig)
  end

  it 'sets exp = now + ttl' do
    expect(challenge[:exp]).to eq(now + ttl)
  end

  it 'base64-encodes the raw salt' do
    expect(challenge[:salt]).to eq(Base64.strict_encode64(salt))
  end

  it 'stores the injected id' do
    expect(challenge[:id]).to eq(id)
  end

  it 'produces a non-empty sig' do
    expect(challenge[:sig]).not_to be_empty
  end

  it 'uses SecureRandom defaults when salt/id are not injected' do
    first, second = Array.new(2) do
      described_class.issue(alg:, params:, request_fingerprint: fingerprint, secret:, ttl:, now:)
    end
    expect(first[:id]).not_to eq(second[:id])
    expect(first[:salt]).not_to eq(second[:salt])
  end
end

RSpec.describe Kiosk::Reputation::Challenge, '.verify outcomes' do
  include_context 'with a challenge fixture'

  it 'returns :ok for a correct nonce and matching fingerprint/secret' do
    expect(verify_challenge).to eq(:ok)
  end

  it 'returns :bad_proof when the nonce is wrong but the challenge is valid' do
    expect(verify_challenge(nonce: 'bad')).to eq(:bad_proof)
  end

  it 'returns :expired when now >= exp' do
    expect(verify_challenge(now: now + ttl + 1)).to eq(:expired)
  end
end

RSpec.describe Kiosk::Reputation::Challenge, '.check' do
  include_context 'with a challenge fixture'

  before { register_spy_backend }

  def check_challenge(**overrides)
    described_class.check(challenge:, request_fingerprint: fingerprint, secret:, now: now + 1, **overrides)
  end

  it 'answers nil for a live challenge this secret signed, without running the backend' do
    expect(check_challenge).to be_nil
  end

  it 'answers :bad_sig for a challenge whose exp the caller moved' do
    expect(check_challenge(challenge: challenge.merge(exp: challenge[:exp] + 86_400))).to eq(:bad_sig)
  end

  it 'answers :expired for a challenge past its exp' do
    expect(check_challenge(now: now + ttl + 1)).to eq(:expired)
  end
end

RSpec.describe Kiosk::Reputation::Challenge, '.verify answers :bad_sig' do
  include_context 'with a challenge fixture'

  it 'returns :bad_sig when params are tampered' do
    expect(verify_challenge(challenge: challenge.merge(params: { n: 168, k: 9 }))).to eq(:bad_sig)
  end

  it 'returns :bad_sig when salt is tampered' do
    expect(verify_challenge(challenge: challenge.merge(salt: Base64.strict_encode64('X' * 16)))).to eq(:bad_sig)
  end

  it 'returns :bad_sig when exp is tampered' do
    expect(verify_challenge(challenge: challenge.merge(exp: now + ttl + 9999))).to eq(:bad_sig)
  end

  it 'returns :bad_sig when request_fingerprint at verify differs from issue' do
    expect(verify_challenge(request_fingerprint: 'fp:different')).to eq(:bad_sig)
  end

  it 'returns :bad_sig when a wrong secret is used at verify' do
    expect(verify_challenge(secret: 'wrong-secret')).to eq(:bad_sig)
  end

  it 'returns :bad_sig when the sig field itself is corrupted' do
    expect(verify_challenge(challenge: challenge.merge(sig: 'deadbeef' * 8))).to eq(:bad_sig)
  end
end

# The spy backend raises if the expensive evaluation runs before the cheap checks.
RSpec.describe Kiosk::Reputation::Challenge, '.verify cheap checks run before the backend' do
  include_context 'with a challenge fixture'

  before { register_spy_backend }

  it 'does not invoke the backend when sig is wrong (uses spy backend)' do
    expect { verify_challenge(challenge: challenge.merge(sig: "#{'badbad' * 10}ab")) }.not_to raise_error
  end

  it 'does not invoke the backend for an expired challenge (uses spy backend)' do
    expect { verify_challenge(now: now + ttl + 1) }.not_to raise_error
  end

  it 'returns :expired (not any other symbol) for the expired spy scenario' do
    expect(verify_challenge(now: now + ttl + 1)).to eq(:expired)
  end

  it 'rejects off-spec params without spending a backend eval (spy backend)' do
    cheap  = issue_challenge(params: { n: 8, k: 1 })
    result = nil
    expect do
      result = verify_challenge(challenge: cheap, expect: { alg: 'equihash', params: { n: 168, k: 7 } })
    end.not_to raise_error
    expect(result).to eq(:bad_params)
  end
end

# The sig proves that we minted the challenge, not that its params are still
# the difficulty the server demands. Each challenge here has a valid sig, a live
# exp and an accepted nonce; only its params differ from `expect:`.
RSpec.describe Kiosk::Reputation::Challenge, '.verify answers :bad_params' do
  include_context 'with a challenge fixture'

  let(:demanded) { { alg: 'equihash', params: { n: 168, k: 7 } } }

  it 'returns :ok when the challenge names exactly the expected alg + params' do
    expect(verify_challenge(expect: demanded)).to eq(:ok)
  end

  # Signed with the real secret and bound to the real request: the forgery a
  # leaked secret allows, and a challenge minted just before a difficulty raise.
  it 'REJECTS an HMAC-valid challenge that names cheaper params' do
    expect(verify_challenge(challenge: issue_challenge(params: { n: 8, k: 1 }), expect: demanded)).to eq(:bad_params)
  end

  it 'REJECTS a challenge naming a different alg (backend substitution)' do
    expect(verify_challenge(expect: { alg: 'argon2id', params: { n: 168, k: 7 } })).to eq(:bad_params)
  end

  it 'rejects a single changed param value' do
    expect(verify_challenge(expect: { alg: 'equihash', params: { n: 168, k: 8 } })).to eq(:bad_params)
  end

  it 'rejects params with an extra key the server does not demand' do
    expect(verify_challenge(expect: { alg: 'equihash', params: { n: 168, k: 7, rounds: 3 } })).to eq(:bad_params)
  end

  it 'keeps the pre-K-541 behaviour when expect: is omitted (opt-in check)' do
    expect(verify_challenge(challenge: issue_challenge(params: { n: 8, k: 1 }))).to eq(:ok)
  end
end

RSpec.describe Kiosk::Reputation::Challenge, '.verify check order' do
  include_context 'with a challenge fixture'

  it 'still reports :bad_sig (not :bad_params) when the sig is also wrong' do
    tampered = challenge.merge(sig: 'deadbeef' * 8)
    expect(verify_challenge(challenge: tampered, expect: { alg: 'equihash', params: { n: 8, k: 1 } })).to eq(:bad_sig)
  end

  it 'still reports :expired (not :bad_params) when the challenge is also dead' do
    expect(verify_challenge(challenge: issue_challenge(params: { n: 8, k: 1 }), now: now + ttl + 1,
                            expect: { alg: 'equihash', params: { n: 168, k: 7 } })).to eq(:expired)
  end
end

# `expect:` is compared in the signed rendering, so there are no false rejections.
RSpec.describe Kiosk::Reputation::Challenge, '.verify expect: equality' do
  include_context 'with a challenge fixture'

  it 'ignores key ORDER in the expected params' do
    expect(verify_challenge(expect: { alg:, params: { k: 7, n: 168 } })).to eq(:ok)
  end

  it 'ignores Symbol-vs-String param keys' do
    expect(verify_challenge(expect: { alg:, params: { 'n' => 168, 'k' => 7 } })).to eq(:ok)
  end

  it 'ignores Integer-vs-String param values (one identical signed string)' do
    expect(verify_challenge(expect: { alg:, params: { n: '168', k: '7' } })).to eq(:ok)
  end

  it 'accepts a String-keyed expect hash' do
    expect(verify_challenge(expect: { 'alg' => 'equihash', 'params' => { n: 168, k: 7 } })).to eq(:ok)
  end

  it 'skips the alg check when expect omits :alg' do
    expect(verify_challenge(expect: { params: { n: 168, k: 7 } })).to eq(:ok)
  end

  it 'skips the params check when expect omits :params' do
    expect(verify_challenge(expect: { alg: 'equihash' })).to eq(:ok)
  end
end

# A JSON round trip delivers string keys ({"n"=>168,"k"=>7}); they still verify.
RSpec.describe Kiosk::Reputation::Challenge, '.verify with string-keyed params' do
  include_context 'with a challenge fixture'

  let(:string_challenge) { issue_challenge(params: { 'n' => 168, 'k' => 7 }) }

  it 'returns :ok for a string-keyed challenge with a correct nonce' do
    expect(verify_challenge(challenge: string_challenge)).to eq(:ok)
  end

  it 'produces the same sig as the symbol-keyed challenge (key type is invisible to the sig)' do
    expect(string_challenge[:sig]).to eq(challenge[:sig])
  end
end

# A nil or non-Hash params raises a typed ArgumentError, never a NoMethodError.
RSpec.describe Kiosk::Reputation::Challenge, 'with malformed (nil / non-Hash) params' do
  include_context 'with a challenge fixture'

  [nil, 'n=168,k=7', [%i[n k]], 42].each do |bad|
    it "raises a typed ArgumentError (not NoMethodError) from .issue for #{bad.inspect}" do
      expect { issue_challenge(params: bad) }.to raise_error(ArgumentError, /params must be a Hash/)
    end

    it "raises a typed ArgumentError (not NoMethodError) from .verify for #{bad.inspect}" do
      expect { verify_challenge(challenge: challenge.merge(params: bad)) }
        .to raise_error(ArgumentError, /params must be a Hash/)
    end
  end

  it 'raises ArgumentError specifically, never the pre-guard NoMethodError' do
    raised = begin
      issue_challenge(params: nil)
    rescue StandardError => e
      e
    end
    expect(raised).to be_a(ArgumentError)
    expect(raised).not_to be_a(NoMethodError)
  end
end

# A delimiter inside a value gives the canonical string a second pre-image, so
# one signature covers two (alg, params) splits.
RSpec.describe Kiosk::Reputation::Challenge, '.issue refuses a delimiter in a field' do
  include_context 'with a challenge fixture'

  it 'refuses an alg carrying the field delimiter' do
    expect { issue_challenge(alg: 'equi|hash') }.to raise_error(ArgumentError, /ambiguous.*alg .* contains/)
  end

  it 'refuses an id carrying the field delimiter' do
    expect { issue_challenge(id: 'a|b') }.to raise_error(ArgumentError, /ambiguous.*id .* contains/)
  end

  it 'refuses a request fingerprint carrying the field delimiter' do
    expect { issue_challenge(request_fingerprint: 'fp|forged') }
      .to raise_error(ArgumentError, /ambiguous.*request_fingerprint .* contains/)
  end

  it 'still mints the ordinary challenge (control)' do
    expect(challenge[:sig]).not_to be_empty
  end
end

RSpec.describe Kiosk::Reputation::Challenge, '.issue refuses a delimiter in params' do
  include_context 'with a challenge fixture'

  [['|', :outer], [',', :param], ['=', :kv]].each do |delim, name|
    it "refuses a params KEY carrying the #{name} delimiter" do
      expect { issue_challenge(params: { "n#{delim}x" => 168 }) }
        .to raise_error(ArgumentError, /ambiguous.*params key .* contains/)
    end

    it "refuses a params VALUE carrying the #{name} delimiter" do
      expect { issue_challenge(params: { n: "168#{delim}7" }) }
        .to raise_error(ArgumentError, /ambiguous.*params value .* contains/)
    end
  end
end

# Re-partitioned params need no delimiter in any issued field, and `expect:`
# cannot see them: `{n: 168, k: 7}` renders `k=7,n=168`, and so do both of these.
RSpec.describe Kiosk::Reputation::Challenge, '.verify refuses a re-partitioned submission' do
  include_context 'with a challenge fixture'

  [{ 'k=7,n' => '168' }, { 'k' => '7,n=168' }].each do |repartition|
    it "answers :bad_params for #{repartition.inspect} under the honest sig" do
      forged = challenge.merge(params: repartition)
      expect(forged[:sig]).to eq(challenge[:sig])
      expect(verify_challenge(challenge: forged)).to eq(:bad_params)
    end

    it "answers :bad_params for #{repartition.inspect} even WITH expect:" do
      expect(verify_challenge(challenge: challenge.merge(params: repartition), expect: { alg:, params: })).to eq(:bad_params)
    end
  end

  it 'does not invoke the backend for a re-partitioned submission' do
    spy = Class.new do
      def self.called? = defined?(@called) && @called
      def self.verify(**) = (@called = true)
    end
    Kiosk::Reputation::Backends.register('equihash', spy)

    verify_challenge(challenge: challenge.merge(params: { 'k=7,n' => '168' }))
    expect(spy.called?).to be_falsey
  end

  it 'leaves the honest echo verifying (control)' do
    expect(verify_challenge(expect: { alg:, params: })).to eq(:ok)
  end
end

RSpec.describe Kiosk::Reputation::Challenge, 'canonical string' do
  include_context 'with a challenge fixture'

  it 'produces the same sig regardless of params hash key insertion order' do
    expect(issue_challenge(params: { n: 168, k: 7 })[:sig]).to eq(issue_challenge(params: { k: 7, n: 168 })[:sig])
  end
end
