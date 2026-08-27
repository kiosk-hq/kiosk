# frozen_string_literal: true

require "digest"

RSpec.describe Kiosk::Server::DeviceAuthorization do
  describe ".generate" do
    it "returns [plain_device_code, plain_user_code, DeviceAuthorization]" do
      plain_code, plain_user_code, da = described_class.generate(client_id: "kiosk-cli")

      expect(plain_code).to be_a(String)
      expect(plain_user_code).to be_a(String)
      expect(da).to be_a(described_class)
    end

    it "starts in :pending status with no user_id and no consumed_at" do
      _plain, _user, da = described_class.generate(client_id: "kiosk-cli")
      expect(da).to be_pending
      expect(da.user_id).to     be_nil
      expect(da.consumed_at).to be_nil
    end

    it "defaults to kind :claim" do
      _plain, _user, da = described_class.generate(client_id: "kiosk-cli")
      expect(da.kind).to eq(:claim)
      expect(da).to be_claim
    end

    it "accepts kind :link" do
      _plain, _user, da = described_class.generate(client_id: "kiosk-link", kind: :link)
      expect(da).to be_link
    end

    it "rejects an unknown kind" do
      expect { described_class.generate(client_id: "kiosk-cli", kind: :wat) }
        .to raise_error(ArgumentError, /kind must be/)
    end

    it "captures the public key the ceremony will bind" do
      _plain, _user, da = described_class.generate(client_id: "kiosk-cli", public_key_pem: "PEM")
      expect(da.public_key_pem).to eq("PEM")
    end

    it "defaults public_key_pem to nil (link rows receive the key at redeem)" do
      _plain, _user, da = described_class.generate(client_id: "kiosk-link", kind: :link)
      expect(da.public_key_pem).to be_nil
    end

    it "persists only the SHA-256 hex digest of the device_code (not plain)" do
      plain, _user, da = described_class.generate(client_id: "kiosk-cli")
      expect(da.device_code_hash).to eq(Digest::SHA256.hexdigest(plain))
      expect(da.respond_to?(:device_code)).to be(false)
    end

    it "persists only the SHA-256 hex digest of the user_code (not plain)" do
      _plain, plain_user_code, da = described_class.generate(client_id: "kiosk-cli")
      expect(da.user_code_hash).to eq(Digest::SHA256.hexdigest(plain_user_code))
      expect(da.respond_to?(:user_code)).to be(false)
    end

    it "produces a user_code of length 8 from the 31-char alphabet (no 0/1/I/L/O)" do
      _plain, plain_user_code, = described_class.generate(client_id: "kiosk-cli")
      expect(plain_user_code.length).to eq(8)
      expect(plain_user_code).to match(/\A[ABCDEFGHJKMNPQRSTUVWXYZ23456789]+\z/)
    end

    it "captures the requested role when provided" do
      _plain, _user, da = described_class.generate(client_id: "kiosk-cli", requested_role: "customer")
      expect(da.requested_role).to eq("customer")
    end

    it "accepts a nil requested_role (caller may negotiate later)" do
      _plain, _user, da = described_class.generate(client_id: "kiosk-cli")
      expect(da.requested_role).to be_nil
    end

    it "computes expires_at as now + expires_in" do
      now = Time.utc(2026, 6, 14, 12, 0, 0)
      _plain, _user, da = described_class.generate(client_id: "kiosk-cli", expires_in: 600, now: now)
      expect(da.expires_at).to eq(now + 600)
    end

    it "defaults expires_in to the canonical 900s (15 min)" do
      now = Time.now
      _plain, _user, da = described_class.generate(client_id: "kiosk-cli", now: now)
      expect(da.expires_at - now).to be_within(1).of(described_class::DEFAULT_EXPIRES_IN)
    end

    it "rejects empty client_id" do
      expect { described_class.generate(client_id: "") }
        .to raise_error(ArgumentError, /client_id/)
    end

    it "rejects non-positive expires_in" do
      expect { described_class.generate(client_id: "kiosk-cli", expires_in: 0) }
        .to raise_error(ArgumentError, /expires_in/)
      expect { described_class.generate(client_id: "kiosk-cli", expires_in: -1) }
        .to raise_error(ArgumentError, /expires_in/)
    end

    it "produces distinct device_codes across calls (CSPRNG sanity)" do
      codes = 10.times.map { described_class.generate(client_id: "kiosk-cli").first }
      expect(codes.uniq.size).to eq(10)
    end

    it "produces distinct user_codes across calls (31^8 collision space)" do
      codes = 50.times.map { described_class.generate(client_id: "kiosk-cli")[1] }
      expect(codes.uniq.size).to eq(50)
    end
  end

  # K-888: the comment above USER_CODE_ALPHABET published a character set and
  # a brute-force space that the constant did not have -- "32 unambiguous
  # chars (no 0/O/1/I/L/U)", 32^8, against a 31-char string that CONTAINS U.
  # The count is the load-bearing half of the published brute-force argument
  # (the other half, the verify page's attempt cap, lives in the session), so
  # it is pinned here rather than trusted to a comment.
  describe "USER_CODE_ALPHABET" do
    subject(:alphabet) { described_class::USER_CODE_ALPHABET }

    it "has exactly 31 characters, the number the comment publishes" do
      expect(alphabet.size).to eq(31)
    end

    it "excludes 0/1/I/L/O -- the read-aloud-ambiguous pairs -- and nothing else" do
      expect(alphabet).not_to include(*%w[0 1 I L O])
      expected = (("A".."Z").to_a - %w[I L O]) + ("2".."9").to_a
      expect(alphabet.sort).to eq(expected.sort)
    end

    it "keeps U, so it is NOT Crockford base32 and must not claim to be" do
      expect(alphabet).to include("U")
      crockford = ("0".."9").to_a + (("A".."Z").to_a - %w[I L O U])
      expect(alphabet.sort).not_to eq(crockford.sort)
    end

    it "mints codes drawn only from the alphabet, at the documented length" do
      _device, user_code, = described_class.generate(client_id: "kiosk-cli", kind: :claim,
                                                     public_key_pem: "PEM")
      expect(user_code.length).to eq(described_class::USER_CODE_LENGTH)
      expect(user_code.chars - alphabet).to be_empty
    end

    it "yields the 31^8 ~ 8.5 x 10^11 code space the comments publish" do
      expect(described_class::USER_CODE_LENGTH).to eq(8)
      space = alphabet.size**described_class::USER_CODE_LENGTH
      expect(space).to eq(31**8)
      expect(space / 1e11).to be_within(0.05).of(8.5)
    end

    # The prose is the thing that drifted, and it drifted at five sites while
    # the constant stayed right, so the sweep is pinned too: no shipped
    # comment may call this alphabet Crockford (except to deny it) or quote
    # the retired 32^8 / "no 0/O/1/I/L/U" figures.
    it "is described as neither Crockford nor 32^8 anywhere in lib or app" do
      root = File.expand_path("../../..", __dir__)
      offenders = Dir.glob("#{root}/{lib,app}/**/*.{rb,erb}").sort.flat_map do |path|
        File.readlines(path).each_with_index.filter_map do |line, idx|
          next unless line.match?(%r{32\^8|32\*\*8|no 0/O/1/I/L/U}) ||
                      (line.include?("Crockford") && !line.include?("NOT Crockford"))

          "#{path.delete_prefix("#{root}/")}:#{idx + 1}"
        end
      end
      expect(offenders).to be_empty
    end
  end

  describe ".hash_device_code" do
    it "matches the hash baked into a generated row" do
      plain, _user, da = described_class.generate(client_id: "kiosk-cli")
      expect(described_class.hash_device_code(plain)).to eq(da.device_code_hash)
    end
  end

  describe ".hash_user_code" do
    it "matches the hash baked into a generated row" do
      _plain, plain_user_code, da = described_class.generate(client_id: "kiosk-cli")
      expect(described_class.hash_user_code(plain_user_code)).to eq(da.user_code_hash)
    end
  end

  describe "status validation" do
    let(:base_attrs) do
      described_class.generate(client_id: "kiosk-cli").last.to_h
    end

    it "accepts the five canonical statuses" do
      described_class::STATUSES.each do |status|
        expect { described_class.new(**base_attrs.merge(status: status)) }.not_to raise_error
      end
    end

    it "rejects any other symbol" do
      expect { described_class.new(**base_attrs.merge(status: :wat)) }
        .to raise_error(ArgumentError, /status must be/)
    end

    it "rejects any kind outside claim/link" do
      expect { described_class.new(**base_attrs.merge(kind: :wat)) }
        .to raise_error(ArgumentError, /kind must be/)
    end
  end

  describe "lifecycle transitions" do
    let(:pending) { described_class.generate(client_id: "kiosk-cli", requested_role: "customer").last }
    let(:user_id) { "11111111-1111-1111-1111-111111111111" }

    describe "#approve" do
      it "transitions pending → approved with user_id set" do
        approved = pending.approve(user_id: user_id)
        expect(approved).to be_approved
        expect(approved.user_id).to eq(user_id)
      end

      it "returns a new instance (immutability)" do
        approved = pending.approve(user_id: user_id)
        expect(approved).not_to equal(pending)
        expect(pending).to be_pending
      end

      it "rejects approving a non-pending row" do
        approved = pending.approve(user_id: user_id)
        expect { approved.approve(user_id: user_id) }
          .to raise_error(described_class::StateError, /approve.*approved/)
      end

      it "rejects missing user_id" do
        expect { pending.approve(user_id: nil) }
          .to raise_error(ArgumentError, /user_id/)
      end

      # ── the role travels with the approval (K-1109) ──────────────────────
      #
      # A `:claim` row is born role-less (its opening request is
      # unauthenticated and refuses to carry a role), so `role:` here is the
      # ONLY way a claim ceremony acquires one — from the approving human's
      # `Identity#role`.
      it "stamps the approving human's role onto a role-less row" do
        fresh = described_class.generate(client_id: "kiosk-cli").last
        expect(fresh.requested_role).to be_nil

        approved = fresh.approve(user_id: user_id, role: "owner")
        expect(approved.requested_role).to eq("owner")
      end

      it "normalises a symbol role to a String" do
        fresh = described_class.generate(client_id: "kiosk-cli").last
        expect(fresh.approve(user_id: user_id, role: :owner).requested_role).to eq("owner")
      end

      # A `:link` row travels the other way: the human MINTS it, so its role is
      # already on the row and `LinkCode.mint` approves with no `role:`. nil
      # therefore means "nothing new to stamp", never "clear what is there" —
      # an unconditional overwrite here would silently delete every link
      # ceremony's captured role.
      it "leaves an already-captured role alone when approved with no role" do
        link = described_class.generate(
          client_id: "kiosk-link", kind: :link, requested_role: "owner",
        ).last
        expect(link.approve(user_id: user_id).requested_role).to eq("owner")
      end

      it "leaves the row role-less when neither side supplies one" do
        fresh = described_class.generate(client_id: "kiosk-cli").last
        expect(fresh.approve(user_id: user_id).requested_role).to be_nil
      end
    end

    describe "#deny" do
      it "transitions pending → denied" do
        denied = pending.deny
        expect(denied).to be_denied
      end

      it "rejects denying a non-pending row" do
        denied = pending.deny
        expect { denied.deny }
          .to raise_error(described_class::StateError, /deny.*denied/)
      end
    end

    describe "#consume" do
      it "transitions approved → consumed with consumed_at set" do
        approved = pending.approve(user_id: user_id)
        now      = Time.now
        consumed = approved.consume(now: now)
        expect(consumed).to be_consumed
        expect(consumed.consumed_at).to eq(now)
      end

      it "rejects consuming a pending row (must be approved first)" do
        expect { pending.consume }
          .to raise_error(described_class::StateError, /consume.*pending/)
      end

      it "rejects consuming an already-consumed row" do
        consumed = pending.approve(user_id: user_id).consume
        expect { consumed.consume }
          .to raise_error(described_class::StateError, /consume.*consumed/)
      end
    end

    describe "#expire" do
      it "transitions pending → expired" do
        expect(pending.expire).to be_expired
      end

      it "transitions approved → expired (consumer never showed up)" do
        approved = pending.approve(user_id: user_id)
        expect(approved.expire).to be_expired
      end

      it "rejects expiring a denied or consumed row" do
        denied = pending.deny
        expect { denied.expire }.to raise_error(described_class::StateError)

        consumed = pending.approve(user_id: user_id).consume
        expect { consumed.expire }.to raise_error(described_class::StateError)
      end
    end
  end

  describe "#expired_at_time?" do
    let(:da) {
      described_class.generate(client_id: "kiosk-cli", expires_in: 600, now: Time.utc(2026, 6, 14, 12, 0, 0)).last
    }

    it "false when now < expires_at" do
      expect(da.expired_at_time?(Time.utc(2026, 6, 14, 12, 5, 0))).to be(false)
    end

    it "true when now >= expires_at" do
      expect(da.expired_at_time?(Time.utc(2026, 6, 14, 12, 10, 0))).to be(true)
      expect(da.expired_at_time?(Time.utc(2026, 6, 14, 13, 0, 0))).to be(true)
    end
  end

  describe ".display_user_code" do
    it "formats a plain user_code as XXXX-XXXX for human display" do
      _plain, plain_user_code, = described_class.generate(client_id: "kiosk-cli")
      display = described_class.display_user_code(plain_user_code)
      expect(display).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
      expect(display.tr("-", "")).to eq(plain_user_code)
    end
  end
end
