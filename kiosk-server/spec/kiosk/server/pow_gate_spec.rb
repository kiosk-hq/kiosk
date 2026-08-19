# frozen_string_literal: true

require "base64"
require "kiosk/pow"
require "kiosk/reputation"

# Integration tests for the PoW challenge-response gate.
#
# These tests use the REAL Argon2id backend (kiosk-pow) registered at d=4, m=8
# (minimum libargon2 memory — keeps solve time well under 1 s).
# The nil-policy path (the regression guard) is exercised first and runs with
# ZERO kiosk-reputation involvement — that's the make-or-break invariant.
RSpec.describe Kiosk::Server::PowGate do
  # Register the real Argon2id backend before each example so challenge.verify
  # can dispatch to it. Use d=4, m=8 throughout so solving is fast.
  before(:each) do
    Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
  end

  after(:each) do
    Kiosk::Reputation::Backends.reset!
  end

  let(:secret)   { "test-pow-secret-for-unit-tests" }
  let(:identity) { build_identity }

  # ─── shared helper: a policy that ALWAYS demands an argon2id challenge ──
  let(:always_challenge_policy) do
    Class.new(Kiosk::Reputation::Policy) do
      def challenge_for(identity:, verb:, factors:)
        { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8) }
      end
    end.new
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  def configure_with_policy(policy, **extra)
    Kiosk.configure do |c|
      c.reputation_policy = policy
      c.pow_secret        = secret
      extra.each { |k, v| c.send(:"#{k}=", v) }
    end
  end

  # Brute-force a valid nonce for the challenge. With d=4, m=8 this is fast
  # (< 16 evals on average).
  def solve_nonce(challenge)
    salt   = Base64.strict_decode64(challenge[:salt])
    params = (challenge[:params] || {}).transform_keys(&:to_sym)
    nonce  = 0
    nonce += 1 until Kiosk::Pow.verify(salt: salt, params: params, nonce: nonce)
    nonce.to_s
  end

  # Find a nonce that FAILS the PoW (15/16 nonces fail at d=4 — found in a
  # couple tries on average).
  def find_bad_nonce(challenge)
    salt   = Base64.strict_decode64(challenge[:salt])
    params = (challenge[:params] || {}).transform_keys(&:to_sym)
    (0..1000).each do |n|
      candidate = "BAD-NONCE-#{n}"
      return candidate unless Kiosk::Pow.verify(salt: salt, params: params, nonce: candidate)
    end
    raise "Could not find a failing nonce in 1000 tries (very unlikely at d=4)"
  end

  # Issue the challenge from the gate — extract from the PowRequired exception.
  #
  # `command` is the gate/POLICY verb the policy branches on; `method` and
  # `verb` are what §3.4's fingerprint binds to and default exactly as
  # {PowGate.gate} defaults them (POST, and the command as the wire name), so a
  # caller that only cares about the policy verb passes neither.
  def issue_challenge_via_gate(command: "query", body: { name: "menu" },
                               method: "POST", verb: nil)
    described_class.gate(identity: identity, command: command, method: method,
                         verb: verb, body: body, pow: nil)
  rescue Kiosk::Server::Errors::PowRequired => e
    e.challenges.first
  end

  # ─── request_fingerprint ──────────────────────────────────────────────────

  # ─── the §3.4 digest: SHA256("<METHOD> <verb>\n<canonical args>") ─────────
  #
  # 0.3 hashed `"<command>\n<body>"`: with every read multiplexed through
  # `POST <endpoint>/query` the method was a constant and the verb name only
  # reached the digest because the wire smuggled it back into the body. On the
  # per-verb wire the method carries the read/write fork and the name is a path
  # segment, so BOTH are hashed directly — and each of the three inputs is
  # separately load-bearing, which is what the four examples below pin.
  describe ".request_fingerprint" do
    it "is deterministic: same inputs → same fingerprint" do
      fp1 = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { q: "milk" })
      fp2 = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { q: "milk" })
      expect(fp1).to eq(fp2)
    end

    it "changes when the HTTP METHOD changes (GET catalog is not POST catalog)" do
      fp_get  = described_class.request_fingerprint(method: "GET",  verb: "catalog", body: { q: "milk" })
      fp_post = described_class.request_fingerprint(method: "POST", verb: "catalog", body: { q: "milk" })
      expect(fp_get).not_to eq(fp_post)
    end

    it "changes when the VERB changes (the path segment, no longer a body field)" do
      fp1 = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { q: "milk" })
      fp2 = described_class.request_fingerprint(method: "GET", verb: "orders",  body: { q: "milk" })
      expect(fp1).not_to eq(fp2)
    end

    it "changes when the body changes" do
      fp1 = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { q: "milk" })
      fp2 = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { q: "bread" })
      expect(fp1).not_to eq(fp2)
    end

    it "upcases the method, so a lower-case spelling is the SAME request" do
      fp_lower = described_class.request_fingerprint(method: "get", verb: "catalog", body: { q: "milk" })
      fp_upper = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { q: "milk" })
      expect(fp_lower).to eq(fp_upper)
    end

    it "is canonical (key-order-independent)" do
      fp1 = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { a: 1, b: 2 })
      fp2 = described_class.request_fingerprint(method: "GET", verb: "catalog", body: { b: 2, a: 1 })
      expect(fp1).to eq(fp2)
    end

    it "treats nil body the same as an empty hash" do
      fp_nil   = described_class.request_fingerprint(method: "GET", verb: "catalog", body: nil)
      fp_empty = described_class.request_fingerprint(method: "GET", verb: "catalog", body: {})
      expect(fp_nil).to eq(fp_empty)
    end

    # The formula itself, pinned: a client solving a challenge has to reproduce
    # this digest byte for byte, so the separator and the ordering are wire
    # contract, not an implementation detail.
    it "is exactly SHA256(\"<METHOD> <verb>\\n<canonical args>\")" do
      expect(described_class.request_fingerprint(method: "get", verb: "catalog", body: { b: 2, a: 1 }))
        .to eq(Digest::SHA256.hexdigest(%(GET catalog\n{"a":1,"b":2})))
    end
  end

  # ─── nil-policy regression (the make-or-break invariant) ─────────────────

  describe "nil reputation_policy (the default)" do
    it "defaults to nil" do
      expect(Kiosk.configuration.reputation_policy).to be_nil
    end

    it "returns :proceed immediately without touching kiosk-reputation" do
      result = described_class.gate(
        identity: identity, command: "query", body: { name: "menu" }, pow: nil,
      )
      expect(result).to eq(:proceed)
    end

    it "returns :proceed even when a pow field is present" do
      result = described_class.gate(
        identity: identity, command: "query", body: { name: "menu" },
        pow: { "challenge" => {}, "nonce" => "123" },
      )
      expect(result).to eq(:proceed)
    end
  end

  # ─── config guard errors ──────────────────────────────────────────────────

  describe "configuration guard: policy set but pow_secret nil" do
    it "raises ConfigurationError mentioning pow_secret" do
      Kiosk.configure { |c| c.reputation_policy = always_challenge_policy }
      # pow_secret intentionally left nil

      expect {
        described_class.gate(identity: identity, command: "query", body: {}, pow: nil)
      }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /pow_secret/)
    end
  end

  # ─── challenge flow ───────────────────────────────────────────────────────

  context "with a policy that always challenges" do
    before { configure_with_policy(always_challenge_policy) }

    # ── first request (no pow) → 402 ────────────────────────────────────────

    describe "first request — no pow submitted" do
      it "raises PowRequired" do
        expect {
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
        }.to raise_error(Kiosk::Server::Errors::PowRequired)
      end

      it "PowRequired carries a well-formed challenge" do
        error = catch_error(Kiosk::Server::Errors::PowRequired) do
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
        end

        ch = error.challenges.first
        expect(ch[:id]).not_to   be_nil
        expect(ch[:alg]).to      eq("argon2id")
        expect(ch[:params]).to   include(:d)
        expect(ch[:salt]).not_to be_nil
        expect(ch[:exp]).to      be > Time.now.to_i
        expect(ch[:sig]).not_to  be_nil
      end

      # The 0.3 `{ok:false, error:{…}}` envelope was DELETED at the cutover.
      # The gate's 402 is an RFC 9457 problem document: the branch point is the
      # TOP-LEVEL `code`, the message is `detail`, and `challenges` survives as
      # an extension member so the client still solves without a second trip.
      it "PowRequired#to_problem renders a pow_required 402 problem document" do
        error = catch_error(Kiosk::Server::Errors::PowRequired) do
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
        end

        problem = error.to_problem
        expect(problem[:type]).to   eq("https://kiosk.tech/problems/pow_required")
        expect(problem[:title]).to  eq("Proof-of-work required")
        expect(problem[:status]).to eq(402)
        expect(problem[:detail]).to eq("proof-of-work required")
        expect(problem[:code]).to   eq("pow_required")
        expect(problem[:challenges]).to be_an(Array)
        expect(problem[:challenges].first).not_to be_nil
        # No trace of the retired envelope, at either nesting.
        expect(problem).not_to have_key(:ok)
        expect(problem).not_to have_key(:error)
        expect(problem).not_to have_key(:message)
        expect(error).not_to respond_to(:to_envelope)
      end

      it "PowRequired has HTTP status 402" do
        error = catch_error(Kiosk::Server::Errors::PowRequired) do
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
        end
        expect(error.http_status).to eq(402)
      end
    end

    # ── retry with valid proof → :proceed ────────────────────────────────────

    describe "retry with a valid proof" do
      it "returns :proceed when the proof is correct" do
        challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        nonce     = solve_nonce(challenge)

        result = described_class.gate(
          identity: identity,
          command:  "query",
          body:     { name: "menu" },
          pow:      { challenge: challenge, nonce: nonce },
        )
        expect(result).to eq(:proceed)
      end
    end

    # ── retry with a wrong nonce → 403 + penalty ─────────────────────────────

    describe "retry with a wrong nonce" do
      it "raises Forbidden" do
        challenge  = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        bad_nonce  = find_bad_nonce(challenge)

        expect {
          described_class.gate(
            identity: identity, command: "query", body: { name: "menu" },
            pow: { challenge: challenge, nonce: bad_nonce },
          )
        }.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
      end

      it "calls on_bad_proof with the identity" do
        penalty_calls = []
        Kiosk.configure { |c| c.on_bad_proof = ->(identity:) { penalty_calls << identity } }

        challenge  = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        bad_nonce  = find_bad_nonce(challenge)

        begin
          described_class.gate(
            identity: identity, command: "query", body: { name: "menu" },
            pow: { challenge: challenge, nonce: bad_nonce },
          )
        rescue Kiosk::Server::Errors::Forbidden
          nil
        end

        expect(penalty_calls).to eq([identity])
      end

      # ── K-512: the 403 must be actionable ──────────────────────────────────
      # A bare "invalid proof of work" is a dead end: a live agent that
      # hand-rolled an Equihash solver got four independent construction
      # errors wrong at once and this 403 told it none of that. The hint names
      # the ONE recovery step — run the shipped solver — and nothing else.

      it "carries a hint steering to the shipped reference solver" do
        challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        bad_nonce = find_bad_nonce(challenge)

        error = catch_error(Kiosk::Server::Errors::Forbidden) do
          described_class.gate(
            identity: identity, command: "query", body: { name: "menu" },
            pow: { challenge: challenge, nonce: bad_nonce },
          )
        end

        # Pinned verbatim: this URL must stay identical to the solver URL the
        # published skill pins (K-490(e)) — the two must not drift.
        expect(error.hint).to eq(
          "solve with the reference solver at https://kiosk.tech/pow/solve.py — " \
          "a hand-written Equihash solver will not match this verifier",
        )
      end

      it "renders the documented forbidden problem document, carrying the hint" do
        challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        bad_nonce = find_bad_nonce(challenge)

        error = catch_error(Kiosk::Server::Errors::Forbidden) do
          described_class.gate(
            identity: identity, command: "query", body: { name: "menu" },
            pow: { challenge: challenge, nonce: bad_nonce },
          )
        end

        # Whole-document equality, as the envelope assertion was: nothing else
        # rides along, and `hint` keeps its own member name under RFC 9457.
        expect(error.to_problem).to eq(
          type:   "https://kiosk.tech/problems/forbidden",
          title:  "Forbidden",
          status: 403,
          detail: "invalid proof of work",
          code:   "forbidden",
          hint:   Kiosk::Server::PowGate::POW_INVALID_HINT,
        )
        expect(error.http_status).to eq(403)
      end

      it "does not disclose the construction, the parameters, or which check failed" do
        challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        bad_nonce = find_bad_nonce(challenge)

        error = catch_error(Kiosk::Server::Errors::Forbidden) do
          described_class.gate(
            identity: identity, command: "query", body: { name: "menu" },
            pow: { challenge: challenge, nonce: bad_nonce },
          )
        end

        wire = "#{error.message} #{error.hint}"
        %w[wagner xor subtree endian salt header_nonce indices thumbprint expired].each do |leak|
          expect(wire.downcase).not_to include(leak)
        end
      end
    end

    # ── proof bound to a DIFFERENT request (fingerprint mismatch) → re-challenge
    #
    # The sig covers §3.4's digest, so a genuinely solved proof is spendable on
    # ONE call and nothing else. All three halves of that digest are exercised
    # here — the method and the verb became bindable only at the 0.4 cutover —
    # and the control example at the end proves the three refusals are not
    # passing for some trivial reason.

    describe "proof issued for a different request" do
      # `GET catalog?q=milk`, the call every example below mints its proof for.
      def catalog_proof(body: { q: "milk" })
        challenge = issue_challenge_via_gate(
          command: "query", method: "GET", verb: "catalog", body: body,
        )
        { challenge: challenge, nonce: solve_nonce(challenge) }
      end

      it "verifies for the identical method + verb + args (the control)" do
        result = described_class.gate(
          identity: identity, command: "query", method: "GET", verb: "catalog",
          body: { q: "milk" }, pow: catalog_proof,
        )
        expect(result).to eq(:proceed)
      end

      it "re-challenges when the ARGUMENTS differ" do
        proof = catalog_proof(body: { q: "milk" })

        expect {
          described_class.gate(
            identity: identity, command: "query", method: "GET", verb: "catalog",
            body: { q: "bread" },              # different args!
            pow:  proof,
          )
        }.to raise_error(Kiosk::Server::Errors::PowRequired)
      end

      it "re-challenges when the METHOD differs (a GET catalog proof on POST catalog)" do
        proof = catalog_proof(body: {})

        expect {
          described_class.gate(
            identity: identity, command: "run", method: "POST", verb: "catalog",
            body: {}, pow: proof,
          )
        }.to raise_error(Kiosk::Server::Errors::PowRequired)
      end

      it "re-challenges when the VERB differs (a catalog proof is not an orders proof)" do
        proof = catalog_proof(body: {})

        expect {
          described_class.gate(
            identity: identity, command: "query", method: "GET", verb: "orders",
            body: {}, pow: proof,
          )
        }.to raise_error(Kiosk::Server::Errors::PowRequired)
      end
    end

    # ── replayed (spent) challenge id → re-challenge (not a penalty) ────────
    #
    # An honest client that solved + submitted + was served but LOST the 200
    # response (timeout / at-least-once HTTP) retries the identical pow. The id
    # is now spent. The correct response is a fresh challenge (402), NOT a 403
    # penalty — a replayed valid proof is not a wrong proof.

    describe "replayed challenge id (spent proof — honest retry)" do
      it "re-issues a fresh challenge (PowRequired / HTTP 402) instead of Forbidden" do
        challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        nonce     = solve_nonce(challenge)
        pow       = { challenge: challenge, nonce: nonce }

        # First submission → accepted
        result = described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: pow)
        expect(result).to eq(:proceed)

        # Replay of the same (now-spent) proof → re-challenge, NOT 403
        expect {
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: pow)
        }.to raise_error(Kiosk::Server::Errors::PowRequired)
      end

      it "re-challenge carries a well-formed NEW challenge (different id from the spent one)" do
        challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        nonce     = solve_nonce(challenge)
        pow       = { challenge: challenge, nonce: nonce }

        described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: pow)

        new_error = catch_error(Kiosk::Server::Errors::PowRequired) do
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: pow)
        end

        new_ch = new_error.challenges.first
        expect(new_ch[:id]).not_to   be_nil
        expect(new_ch[:id]).not_to   eq(challenge[:id])  # fresh id
        expect(new_ch[:alg]).to      eq("argon2id")
        expect(new_ch[:exp]).to      be > Time.now.to_i
      end

      it "does NOT call on_bad_proof (replaying a valid proof is not a wrong proof)" do
        penalty_calls = []
        Kiosk.configure { |c| c.on_bad_proof = ->(identity:) { penalty_calls << identity } }

        challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
        nonce     = solve_nonce(challenge)
        pow       = { challenge: challenge, nonce: nonce }

        described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: pow)

        begin
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: pow)
        rescue Kiosk::Server::Errors::PowRequired
          nil
        end

        expect(penalty_calls).to be_empty
      end
    end

    # ── malformed proof: challenge missing a params object (K-551) ───────────
    # A challenge echoed back WITHOUT a `params` object would 500 inside the
    # challenge sig computation (`nil.sort_by`). The gate rejects it as a clean
    # bad_request first, before the claim or any hash work.

    describe "malformed proof (challenge without params)" do
      it "raises BadRequest (400), not a 500, when challenge.params is missing" do
        malformed = { id: "x", alg: "argon2id", salt: "abc",
                      exp: Time.now.to_i + 300, sig: "deadbeef" }
        expect {
          described_class.gate(
            identity: identity, command: "query", body: { name: "menu" },
            pow: { challenge: malformed, nonce: "1" },
          )
        }.to raise_error(Kiosk::Server::Errors::BadRequest, /params/)
      end
    end

    # ── policy that challenges only some verbs ────────────────────────────────

    describe "policy that returns nil for some verbs (free pass)" do
      let(:selective_policy) do
        Class.new(Kiosk::Reputation::Policy) do
          def challenge_for(identity:, verb:, factors:)
            return nil if verb == :run
            { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8) }
          end
        end.new
      end

      before { configure_with_policy(selective_policy) }

      it "returns :proceed for a verb the policy exempts" do
        result = described_class.gate(identity: identity, command: "run", body: { name: "ping" }, pow: nil)
        expect(result).to eq(:proceed)
      end

      it "raises PowRequired for a verb the policy challenges" do
        expect {
          described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
        }.to raise_error(Kiosk::Server::Errors::PowRequired)
      end
    end
  end

  # ─── on_proof_verified hook (duck-typed, opt-in) ──────────────────────────
  #
  # After the gate verifies a submitted proof (a real solve), it calls
  # #on_proof_verified on the policy IF the policy defines it. Policies that
  # don't (the base Policy, RateAndReputation, always_challenge_policy) are
  # unaffected — the whole existing suite above uses hookless policies and stays
  # green, which is itself the "duck-typed" proof.
  describe "on_proof_verified hook after a verified solve" do
    # A hookless always-challenge policy that ALSO records verified solves.
    let(:hook_calls) { [] }
    let(:recording_policy) do
      recorder = hook_calls
      Class.new(Kiosk::Reputation::Policy) do
        define_method(:on_proof_verified) { |identity:| recorder << identity }
        def challenge_for(identity:, verb:, factors:)
          { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8) }
        end
      end.new
    end

    before { configure_with_policy(recording_policy) }

    it "calls on_proof_verified(identity:) exactly once after a correct proof" do
      challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
      nonce     = solve_nonce(challenge)

      result = described_class.gate(
        identity: identity, command: "query", body: { name: "menu" },
        pow: { challenge: challenge, nonce: nonce },
      )

      expect(result).to eq(:proceed)
      expect(hook_calls).to eq([identity])
    end

    it "does NOT call the hook when a challenge is issued (no proof yet — 402)" do
      expect {
        described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
      }.to raise_error(Kiosk::Server::Errors::PowRequired)
      expect(hook_calls).to be_empty
    end

    it "does NOT call the hook on a bad proof (403 raised before the hook)" do
      challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
      bad_nonce = find_bad_nonce(challenge)

      expect {
        described_class.gate(identity: identity, command: "query", body: { name: "menu" },
                             pow: { challenge: challenge, nonce: bad_nonce })
      }.to raise_error(Kiosk::Server::Errors::Forbidden)
      expect(hook_calls).to be_empty
    end

    it "does NOT call the hook on the nil-spec path (policy declines to challenge)" do
      # A policy that both declines (:run → nil) and records solves. The nil-spec
      # path returns :proceed WITHOUT running enforce, so the hook must not fire.
      recorder = hook_calls
      declining = Class.new(Kiosk::Reputation::Policy) do
        define_method(:on_proof_verified) { |identity:| recorder << identity }
        def challenge_for(identity:, verb:, factors:) = nil
      end.new
      configure_with_policy(declining)

      result = described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: nil)
      expect(result).to eq(:proceed)
      expect(hook_calls).to be_empty
    end

    it "is safe for a policy WITHOUT the hook (duck-typed — always_challenge_policy)" do
      configure_with_policy(always_challenge_policy)
      expect(always_challenge_policy).not_to respond_to(:on_proof_verified)

      challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
      nonce     = solve_nonce(challenge)

      result = described_class.gate(
        identity: identity, command: "query", body: { name: "menu" },
        pow: { challenge: challenge, nonce: nonce },
      )
      expect(result).to eq(:proceed)
    end
  end

  # ─── PowSpentStore unit tests ─────────────────────────────────────────────

  describe Kiosk::Server::PowSpentStore do
    let(:store) { described_class.new }
    let(:id)    { "spent-store-test-#{SecureRandom.uuid}" }
    let(:future_exp) { Time.now.to_i + 300 }

    it "returns false for an unknown id" do
      expect(store.spent?(id)).to be(false)
    end

    it "returns true after marking an id spent" do
      store.mark_spent(id, future_exp)
      expect(store.spent?(id)).to be(true)
    end

    it "prunes expired entries and returns false for them" do
      past_exp = Time.now.to_i - 1
      store.mark_spent(id, past_exp)
      # Trigger prune by checking another id
      store.spent?("trigger-prune-#{SecureRandom.uuid}")
      expect(store.spent?(id)).to be(false)
    end

    it "returns false safely for a nil id" do
      expect(store.spent?(nil)).to be(false)
    end

    # ── atomic single-use claim (K-542) ────────────────────────────────────

    it "#claim returns true the first time and false on a repeat of the same id" do
      expect(store.claim(id, future_exp)).to be(true)
      expect(store.claim(id, future_exp)).to be(false)
    end

    it "#claim returns false safely for a nil id" do
      expect(store.claim(nil, future_exp)).to be(false)
    end

    it "#release frees a claimed id so it can be claimed again" do
      store.claim(id, future_exp)
      store.release(id)
      expect(store.claim(id, future_exp)).to be(true)
    end

    # The core K-542 property, at the store contract: N threads racing to claim
    # ONE id — exactly one wins. A non-atomic check-then-set would let several
    # through.
    it "lets exactly one of N racing threads claim the same id" do
      race_id = "race-#{SecureRandom.uuid}"
      n       = 50
      latch   = Queue.new
      threads = Array.new(n) do
        Thread.new do
          latch.pop
          store.claim(race_id, future_exp)
        end
      end
      n.times { latch.push(:go) }
      wins = threads.map(&:value).count(true)
      expect(wins).to eq(1)
    end
  end

  # ─── K-542: a valid proof is single-use even under concurrency ─────────────
  # pow_gate.rb used to `spent?` then (after the ~17 ms verify) `mark_spent`,
  # with no atomic claim in between: M parallel submissions of ONE valid proof
  # all passed `spent?` before any `mark_spent` and all proceeded (a probe saw
  # 20/20). The gate now claims the id atomically BEFORE the verify, so a single
  # proof id is accepted exactly once across N racing submissions.
  context "concurrent submission of one valid proof (spent-store TOCTOU)" do
    # A backend whose verify always succeeds but SLEEPS, widening the
    # claim-vs-verify window so the race is deterministic. sleep releases the
    # GVL, so every racing thread sits inside verify simultaneously — on the
    # pre-fix code all of them pass the `spent?` check first.
    let(:slow_ok_backend) do
      Class.new do
        def verify(salt:, params:, nonce:)
          sleep 0.05
          true
        end
      end.new
    end

    let(:slow_ok_policy) do
      Class.new(Kiosk::Reputation::Policy) do
        def challenge_for(identity:, verb:, factors:)
          { alg: "slowtest", params: { d: 1 } }
        end
      end.new
    end

    before do
      Kiosk::Reputation::Backends.register("slowtest", slow_ok_backend)
      configure_with_policy(slow_ok_policy)
    end

    it "accepts one proof id exactly once across N racing submissions" do
      challenge = issue_challenge_via_gate(command: "query", body: { name: "menu" })
      pow       = { challenge: challenge, nonce: "n" }
      n         = 20
      latch     = Queue.new

      threads = Array.new(n) do
        Thread.new do
          latch.pop
          begin
            described_class.gate(identity: identity, command: "query", body: { name: "menu" }, pow: pow)
          rescue Kiosk::Server::Errors::PowRequired
            :rechallenged
          end
        end
      end
      n.times { latch.push(:go) }
      results = threads.map(&:value)

      expect(results.count(:proceed)).to eq(1)
      expect(results.count(:rechallenged)).to eq(n - 1)
    end
  end

  # ─── configuration extension defaults ─────────────────────────────────────

  describe "new config slots (defaults)" do
    it "reputation_policy defaults to nil" do
      expect(Kiosk.configuration.reputation_policy).to be_nil
    end

    it "pow_secret defaults to nil" do
      expect(Kiosk.configuration.pow_secret).to be_nil
    end

    it "pow_ttl defaults to 300" do
      expect(Kiosk.configuration.pow_ttl).to eq(300)
    end

    it "on_bad_proof default is a no-op callable" do
      cb = Kiosk.configuration.on_bad_proof
      expect(cb).to respond_to(:call)
      expect { cb.call(identity: identity) }.not_to raise_error
    end

    it "pow_spent_store defaults to a PowSpentStore instance" do
      expect(Kiosk.configuration.pow_spent_store).to be_a(Kiosk::Server::PowSpentStore)
    end

    it "reputation_factors default returns Factors.empty when kiosk-reputation is loaded" do
      cb = Kiosk.configuration.reputation_factors
      expect(cb).to respond_to(:call)
      result = cb.call(identity: identity, verb: :query)
      expect(result).to be_a(Kiosk::Reputation::Factors)
    end

    it "pow_spent_store is fresh after Kiosk.reset!" do
      store_before = Kiosk.configuration.pow_spent_store
      Kiosk.reset!
      store_after = Kiosk.configuration.pow_spent_store
      expect(store_after).not_to be(store_before)
    end
  end

  # ─── N×PoW: policy demands multiple independent proofs ─────────────────────
  # The gate is algorithm-agnostic — argon2id (d=4, m=8) keeps solving fast.
  # Equihash's own verify math is covered in kiosk-pow-equihash. Here we prove
  # the gate's N-proof ORCHESTRATION: N distinct challenges, all-or-re-challenge,
  # no-burn-on-partial, and bad-faith detection.
  context "with a policy that demands N independent proofs (count > 1)" do
    let(:count) { 3 }
    let(:multi_proof_policy) do
      n = count
      Class.new(Kiosk::Reputation::Policy) do
        define_method(:challenge_for) do |identity:, verb:, factors:|
          { alg: "argon2id", params: Kiosk::Pow.params(d: 4, m: 8), count: n }
        end
      end.new
    end

    before { configure_with_policy(multi_proof_policy) }

    def issue_n_challenges(command: "query", body: { name: "menu" })
      err = catch_error(Kiosk::Server::Errors::PowRequired) do
        described_class.gate(identity: identity, command: command, body: body, pow: nil)
      end
      err.challenges
    end

    def solve_all(challenges)
      challenges.map { |ch| { challenge: ch, nonce: solve_nonce(ch) } }
    end

    it "issues `count` challenges with distinct ids AND salts (no amortisation)" do
      challenges = issue_n_challenges
      expect(challenges.length).to eq(count)
      expect(challenges.map { |c| c[:id] }.uniq.length).to eq(count)
      expect(challenges.map { |c| c[:salt] }.uniq.length).to eq(count)
    end

    it "proceeds only when ALL `count` proofs are valid" do
      result = described_class.gate(
        identity: identity, command: "query", body: { name: "menu" },
        pow: { proofs: solve_all(issue_n_challenges) },
      )
      expect(result).to eq(:proceed)
    end

    it "re-challenges when fewer than `count` valid proofs are submitted" do
      proofs = solve_all(issue_n_challenges)
      expect {
        described_class.gate(
          identity: identity, command: "query", body: { name: "menu" },
          pow: { proofs: proofs.first(count - 1) },
        )
      }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end

    it "does NOT spend proofs on a short submission (a later full submission still works)" do
      proofs = solve_all(issue_n_challenges)

      catch_error(Kiosk::Server::Errors::PowRequired) do
        described_class.gate(
          identity: identity, command: "query", body: { name: "menu" },
          pow: { proofs: proofs.first(count - 1) },
        )
      end

      result = described_class.gate(
        identity: identity, command: "query", body: { name: "menu" },
        pow: { proofs: proofs },
      )
      expect(result).to eq(:proceed)
    end

    it "raises Forbidden if any single proof is cryptographically wrong" do
      challenges = issue_n_challenges
      proofs     = solve_all(challenges)
      proofs[1]  = { challenge: challenges[1], nonce: find_bad_nonce(challenges[1]) }

      expect {
        described_class.gate(
          identity: identity, command: "query", body: { name: "menu" },
          pow: { proofs: proofs },
        )
      }.to raise_error(Kiosk::Server::Errors::Forbidden, /invalid proof/)
    end
  end

  # ─── PowRequired error class ──────────────────────────────────────────────

  describe Kiosk::Server::Errors::PowRequired do
    let(:challenge_hash) { { id: "cid-1", alg: "argon2id", params: { d: 4 }, salt: "abc", exp: 9999, sig: "xxx" } }
    subject(:error)      { described_class.new(challenges: [challenge_hash]) }

    it "is a subclass of Errors::Base" do
      expect(error).to be_a(Kiosk::Server::Errors::Base)
    end

    it "has HTTP status 402" do
      expect(error.http_status).to eq(402)
    end

    it "has code 'pow_required'" do
      expect(error.code).to eq("pow_required")
    end

    it "carries the challenges list" do
      expect(error.challenges).to eq([challenge_hash])
    end

    it "accepts a multi-element challenges list" do
      c2 = challenge_hash.merge(id: "cid-2", salt: "def")
      err = described_class.new(challenges: [challenge_hash, c2])
      expect(err.challenges).to eq([challenge_hash, c2])
    end

    it "serialises to the correct problem document (plural challenges)" do
      expect(error.to_problem).to eq(
        type:       "https://kiosk.tech/problems/pow_required",
        title:      "Proof-of-work required",
        status:     402,
        detail:     "proof-of-work required",
        code:       "pow_required",
        challenges: [challenge_hash],
      )
    end
  end

  private

  # Capture a specific exception without letting it propagate.
  def catch_error(klass, &block)
    block.call
    nil
  rescue klass => e
    e
  end
end

# ─── .proofs_from_header — parse the proof(s) out of the Kiosk-PoW header ─────
# The wire carries the proof(s) in the `Kiosk-PoW` request HEADER as raw JSON
# (ADR-0022), NOT in the body — so the body is identical at issue time (no
# proof) and verify time (proof in the header) and the challenge fingerprint
# matches. The parser flattens every accepted presentation (single proof, JSON
# array, repeated header lines joined by "\n", proxy comma-combined) into one
# flat proofs list. Malformed JSON → Errors::BadRequest (400) with a header hint.
RSpec.describe "Kiosk::Server::PowGate.proofs_from_header (b3 dual-accept)" do
  subject(:parse) { Kiosk::Server::PowGate.method(:proofs_from_header) }

  let(:proof_a) { { challenge: { id: "a" }, nonce: { indices: [1] } } }
  let(:proof_b) { { challenge: { id: "b" }, nonce: { indices: [2] } } }

  it "returns nil for an absent header" do
    expect(parse.call(nil)).to be_nil
  end

  it "returns nil for a blank / whitespace-only header" do
    expect(parse.call("")).to be_nil
    expect(parse.call("   ")).to be_nil
  end

  it "wraps a single {…} proof into a one-element proofs list" do
    proofs = parse.call(JSON.generate(proof_a))
    expect(proofs).to eq([proof_a])
  end

  it "parses a JSON-array value into the proofs list" do
    proofs = parse.call(JSON.generate([proof_a, proof_b]))
    expect(proofs).to eq([proof_a, proof_b])
  end

  it "flattens repeated header lines (Rack joins duplicates with \\n)" do
    raw = "#{JSON.generate(proof_a)}\n#{JSON.generate(proof_b)}"
    expect(parse.call(raw)).to eq([proof_a, proof_b])
  end

  it "flattens a proxy comma-combined value {A},{B} (RFC 7230)" do
    raw = "#{JSON.generate(proof_a)},#{JSON.generate(proof_b)}"
    expect(parse.call(raw)).to eq([proof_a, proof_b])
  end

  it "supports N > 10 proofs across repeated lines" do
    lines  = Array.new(12) { |i| JSON.generate(challenge: { id: i.to_s }, nonce: { indices: [i] }) }
    proofs = parse.call(lines.join("\n"))
    expect(proofs.length).to eq(12)
  end

  it "raises Errors::BadRequest with a Kiosk-PoW hint on malformed JSON" do
    expect { parse.call("{not json") }
      .to raise_error(Kiosk::Server::Errors::BadRequest, /Kiosk-PoW/)
  end
end
