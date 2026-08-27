# frozen_string_literal: true

# The binding product of the ceremony: fresh key → linked
# assistant account under the holder's user_id; known key → rebind with
# reputation carried; unlink = registration-layer revocation. DB access is
# exercised against the FakeConnection (the AgentRegistration/AgentLogin
# pattern); tokens are stubbed — kiosk-pop issuance is covered in
# default_agent_idp_spec.rb.
RSpec.describe Kiosk::Server::AccountBinding do
  let(:pem)     { "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----" }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }
  let(:con)     { FakeConnection.new }

  before do
    Kiosk.configure do |c|
      c.roles  = %i[customer]
      c.schema = "kiosk"
    end
    ar_base = class_double("ActiveRecord::Base").as_stubbed_const
    allow(ar_base).to receive(:lease_connection).and_return(con)
    allow(con).to receive(:quote).and_call_original
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:issue).and_return("kiosk-pop-jwt")
  end

  describe ".bind! — fresh key" do
    before do
      # SELECT finds no live agent; INSERT returns the new id.
      route_exec_query(con) { |sql, _binds| sql =~ /INSERT/i ? [{ "id" => "agent-new" }] : [] }
    end

    it "registers a linked assistant account under the holder's user_id" do
      result = described_class.bind!(public_key_pem: pem, user_id: user_id)

      expect(result).to eq(
        agent_id: "agent-new", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: true,
      )
      sql, binds = con.bound(/INSERT/i).first
      expect(sql).to include("kiosk.agents")
      # K-782: the principal is `$1`, the key `$2` — and neither appears in the
      # statement text, which is the property that makes a forgotten `quote`
      # impossible rather than merely absent.
      expect(sql).to include("VALUES ($1, '{}'::text[], $2)")
      expect(binds).to eq([user_id, pem])
      expect(con.all_sql).not_to include(user_id)
      expect(con).not_to have_received(:quote)
    end

    # The lookup that decides fresh-vs-known takes the CALLER's key verbatim.
    it "looks the key up through a bind, so a quote-bearing PEM is just a value" do
      hostile = "-----BEGIN PUBLIC KEY-----\n' OR '1'='1 --\n-----END PUBLIC KEY-----"
      described_class.bind!(public_key_pem: hostile, user_id: user_id)

      sql, binds = con.bound(/SELECT/i).first
      expect(sql).to include("public_key = $1")
      expect(binds).to eq([hostile])
      expect(con.all_sql).not_to include("OR '1'='1")
    end

    it "never invokes the assistant_creation factory (the principal already exists)" do
      factory = ->(_pubkey) { raise "assistant_creation must not run during binding" }
      Kiosk.configure { |c| c.assistant_creation = factory }

      expect { described_class.bind!(public_key_pem: pem, user_id: user_id) }
        .not_to raise_error
    end

    it "does not fire assistant_claimed for a fresh key (nothing was re-bound)" do
      fired = false
      Kiosk.configure { |c| c.assistant_claimed = ->(**) { fired = true } }

      described_class.bind!(public_key_pem: pem, user_id: user_id)
      expect(fired).to be(false)
    end

    it "pins the ceremony's requested_role into allowed_roles" do
      described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: "customer")
      sql, binds = con.bound(/INSERT/i).first
      # `ARRAY[$3]::text[]` and not `$3::text[]`: the cast alone would ask
      # Postgres to parse the role as an ARRAY LITERAL — proven in
      # auth_plane_persistence_spec.rb by removing the ARRAY[] and watching
      # `malformed array literal: "customer"`.
      expect(sql).to include("ARRAY[$3]::text[]")
      expect(binds).to eq([user_id, pem, "customer"])
    end

    it "falls back to registration_role, and the empty role set when neither is set" do
      described_class.bind!(public_key_pem: pem, user_id: user_id)
      sql, binds = con.bound(/INSERT/i).first
      # The empty array is a statement SHAPE (no role at all), so it has no
      # bind. It used to be a literal `NULL`, which the shipped migration's
      # `NOT NULL` rejected on every role-less fresh-key bind (K-788) — a fake
      # cannot see that, so the real proof is in auth_plane_persistence_spec.rb.
      expect(sql).to include("'{}'::text[]")
      expect(sql).not_to include("NULL")
      expect(binds).to eq([user_id, pem])

      Kiosk.configure { |c| c.registration_role = :customer }
      described_class.bind!(public_key_pem: pem, user_id: user_id)
      sql, binds = con.bound(/INSERT/i).last
      expect(sql).to include("ARRAY[$3]::text[]")
      expect(binds).to eq([user_id, pem, "customer"])
    end

    it "raises ConfigurationError for a role outside the declared set" do
      expect {
        described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: "root")
      }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /root/)
    end

    it "requires a user_id (binding without a principal is meaningless)" do
      expect { described_class.bind!(public_key_pem: pem, user_id: nil) }
        .to raise_error(ArgumentError, /user_id/)
    end
  end

  describe ".bind! — known key (rebind, scenario TWO)" do
    let(:previous_user) { "22222222-2222-2222-2222-222222222222" }

    before do
      route_exec_query(con) do |sql, _binds|
        if sql =~ /SELECT/i
          [{ "id" => "agent-known", "user_id" => previous_user, "allowed_roles" => "{customer}" }]
        else
          []
        end
      end
    end

    it "remaps agents.user_id, keeping agent_id stable — no INSERT, reputation untouched" do
      result = described_class.bind!(public_key_pem: pem, user_id: user_id)

      expect(result).to eq(
        agent_id: "agent-known", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: false,
      )
      sql, binds = con.bound(/UPDATE/i).first
      expect(sql).to include("SET user_id = $1")
      expect(sql).to include("WHERE id = $2")
      expect(binds).to eq([user_id, "agent-known"])
      expect(con.bound(/INSERT/i)).to be_empty
      # Reputation carry-over = the binding touches ONLY agents.user_id.
      expect(con.all_sql).not_to match(/reputation|allowed_roles\s*=/i)
      expect(con).not_to have_received(:quote)
    end

    it "fires assistant_claimed(agent:, previous_user_id:, user_id:)" do
      received = nil
      Kiosk.configure do |c|
        c.assistant_claimed = ->(agent:, previous_user_id:, user_id:) {
          received = { agent: agent, previous_user_id: previous_user_id, user_id: user_id }
        }
      end

      described_class.bind!(public_key_pem: pem, user_id: user_id)
      expect(received).to eq(
        agent: "agent-known", previous_user_id: previous_user, user_id: user_id,
      )
    end

    it "runs the hook inside the rebind transaction (a raising hook aborts the rebind)" do
      Kiosk.configure { |c| c.assistant_claimed = ->(**) { raise "vertical migration failed" } }

      expect { described_class.bind!(public_key_pem: pem, user_id: user_id) }
        .to raise_error(RuntimeError, /vertical migration failed/)
    end

    it "mints the token with the agent's OWN registered role" do
      idp = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp
      allow_any_instance_of(idp).to receive(:issue) do |_instance, agent_id:, role:|
        expect(agent_id).to eq("agent-known")
        expect(role).to eq("customer")
        "kiosk-pop-jwt"
      end

      described_class.bind!(public_key_pem: pem, user_id: user_id)
    end

    # roles-from-IdP (Path A): a rebind carrying the NEW human's role
    # remaps allowed_roles in the same UPDATE and mints the token with it —
    # the agent adopts the role of the principal it is now bound to.
    context "when the ceremony carries a requested_role (roles-from-IdP)" do
      before { Kiosk.configure { |c| c.roles = %i[customer stylist owner] } }

      it "remaps allowed_roles to the new human's role in the rebind UPDATE" do
        described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: "owner")

        sql, binds = con.bound(/UPDATE/i).first
        expect(sql).to include("SET user_id = $1")
        expect(sql).to include("allowed_roles = ARRAY[$3]::text[]")
        expect(binds).to eq([user_id, "agent-known", "owner"])
        expect(con.bound(/INSERT/i)).to be_empty # still a rebind
      end

      it "mints the token with the ADOPTED role, not the pre-link one" do
        idp = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp
        allow_any_instance_of(idp).to receive(:issue) do |_instance, agent_id:, role:|
          expect(agent_id).to eq("agent-known")
          expect(role).to eq("stylist") # adopted, not the pre-link "customer"
          "kiosk-pop-jwt"
        end

        described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: "stylist")
      end

      it "rejects a role outside the declared set on rebind (no scope widening)" do
        expect {
          described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: "root")
        }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /root/)
      end
    end

    it "leaves allowed_roles untouched on a role-less rebind (no-IdP providers)" do
      described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: nil)
      expect(con.all_sql).not_to match(/allowed_roles\s*=/i)
    end

    # ── K-1124: what the clause above COSTS, pinned so it cannot move by
    # accident ───────────────────────────────────────────────────────────────
    #
    # "Leaves allowed_roles untouched" is ADR-0011's explicit no-regression
    # clause and it is not being changed here. But read it on a MULTI-ROLE
    # origin and it says something sharper than "single-role providers keep
    # today's behavior": an agent already carrying the privileged role, rebound
    # to a DIFFERENT human who has none, keeps the privilege while `sub` becomes
    # that human's. The example below is a CHARACTERIZATION — it asserts what
    # the engine does, not what it ought to do — so that any future change to
    # this branch is a deliberate edit to a red test rather than a silent one.
    #
    # WHY IT IS NOT A LIVE HOLE, AND WHERE THAT SAFETY ACTUALLY LIVES. Post-K-072
    # a `:claim` row can only be role-less if the approving human's IdP reports
    # no role, and a `:link` row carries the minter's role by construction. In
    # this fleet every ceremony therefore carries one — but that is a property of
    # the HOST's user model, not of the engine and not even of the shipped Devise
    # adapter, whose `#role_for` returns `user.kiosk_role` VERBATIM and will hand
    # back whatever that method answers, `nil` included
    # (`kiosk-user-idp-devise`'s own suite pins that, deliberately). A host whose
    # `#kiosk_role` can answer nil re-arms this branch on the day it declares a
    # second role.
    it "KEEPS a privileged role across a change of principal when the ceremony carries none" do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      route_exec_query(con) do |sql, _binds|
        sql =~ /SELECT/i ? [{ "id" => "agent-known", "user_id" => previous_user,
                              "allowed_roles" => "{owner}" }] : []
      end
      idp = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp
      minted = nil
      allow_any_instance_of(idp).to receive(:issue) do |_instance, agent_id:, role:|
        minted = [agent_id, role]
        "kiosk-pop-jwt"
      end

      result = described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: nil)

      # The principal moved...
      expect(result[:user_id]).to eq(user_id)
      expect(con.bound(/UPDATE/i).first.last).to eq([user_id, "agent-known"])
      # ...and the role did not.
      expect(con.all_sql).not_to match(/allowed_roles\s*=/i)
      expect(minted).to eq(["agent-known", "owner"])
    end

    # A rebind is a principal change, so — like
    # unlink! — it watermark-revokes the key's pre-link tokens.
    it "watermark-revokes the key's pre-link tokens (principal change ⇒ re-login)" do
      expect(Kiosk.configuration.revocation_store)
        .to receive(:revoke_all).with("agent-known", hash_including(:at))

      described_class.bind!(public_key_pem: pem, user_id: user_id)
    end

    # ── K-783: a re-bind that re-binds nothing is not a re-bind ──────────────
    #
    # A human who mints a fresh link code and claims it with a key ALREADY
    # bound to them reaches this path with previous_user_id == user_id.
    # `assistant_claimed` says "the holder changed from A to B, migrate A's
    # rows to B"; firing it when A IS B is the engine telling its host a
    # transition happened when none did, and a host is entitled to act on it.
    # tudu's hook — the only one in the fleet — acted by DELETING every
    # membership the human had.
    #
    # What this guard does NOT touch is as deliberate as what it does: the
    # UPDATE still runs (it carries the roles-from-IdP `allowed_roles` remap,
    # which a same-principal ceremony can legitimately change), and the
    # revocation + fresh token are untouched, so nothing an assistant sees on
    # the wire moved. K-787 settled the once-spec-silent half: protocol.md
    # §6.3 now says NORMATIVELY that a re-bind to the account a key is already
    # bound to is idempotent — it still succeeds, still re-issues, and the
    # previous tokens still stop verifying — so the revocation below is a
    # conformance assertion, not an implementation detail.
    context "when the key is ALREADY bound to this same human (re-link, K-783)" do
      before do
        route_exec_query(con) do |sql, _binds|
          if sql =~ /SELECT/i
            [{ "id" => "agent-known", "user_id" => user_id, "allowed_roles" => "{customer}" }]
          else
            []
          end
        end
      end

      it "does NOT fire assistant_claimed (nothing transitioned)" do
        fired = nil
        Kiosk.configure do |c|
          c.assistant_claimed = ->(agent:, previous_user_id:, user_id:) {
            fired = { agent: agent, previous_user_id: previous_user_id, user_id: user_id }
          }
        end

        described_class.bind!(public_key_pem: pem, user_id: user_id)
        expect(fired).to be_nil
      end

      # The regression in one line: a hook that destroys on a no-op transition
      # must never be reached with one.
      it "never hands the hook a previous_user_id equal to user_id" do
        seen = []
        Kiosk.configure do |c|
          c.assistant_claimed = ->(agent:, previous_user_id:, user_id:) {
            seen << [previous_user_id, user_id]
          }
        end

        described_class.bind!(public_key_pem: pem, user_id: user_id)
        expect(seen).to be_empty
      end

      # A string/uuid-object mismatch must not defeat the comparison — the
      # incoming user_id comes off a device-authorization row, the existing one
      # off the agents SELECT, and the two need not be the same class.
      it "compares by value, not identity (a non-String user_id still counts as the same holder)" do
        fired = false
        Kiosk.configure { |c| c.assistant_claimed = ->(**) { fired = true } }

        uid        = user_id # a local: `self` is rebound inside the block below
        same_value = Object.new
        same_value.define_singleton_method(:to_s) { uid }
        described_class.bind!(public_key_pem: pem, user_id: same_value)
        expect(fired).to be(false)
      end

      # protocol.md §6.3 (K-787): "the ceremony still succeeds, still returns a
      # fresh `access_token`, and the key's previous tokens still stop
      # verifying". The revocation is the half that is invisible in the
      # response, so it needs its own beat — dropping `revoke_all` from this
      # path would leave every other assertion in this context green.
      it "STILL watermark-revokes the key's earlier tokens (idempotent ⇒ still re-issues)" do
        expect(Kiosk.configuration.revocation_store)
          .to receive(:revoke_all).with("agent-known", hash_including(:at))

        result = described_class.bind!(public_key_pem: pem, user_id: user_id)
        expect(result[:access_token]).to eq("kiosk-pop-jwt")
      end

      it "still answers the caller exactly as a rebind does (no new wire semantics)" do
        result = described_class.bind!(public_key_pem: pem, user_id: user_id)

        expect(result).to eq(
          agent_id: "agent-known", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: false,
        )
        expect(con.bound(/INSERT/i)).to be_empty
      end

      # roles-from-IdP: the human's role can change under a stable binding, so
      # the same-principal ceremony is NOT a blanket no-op — the remap lands.
      it "still remaps allowed_roles when the ceremony carries a new role" do
        Kiosk.configure { |c| c.roles = %i[customer owner] }

        described_class.bind!(public_key_pem: pem, user_id: user_id, requested_role: "owner")
        sql, binds = con.bound(/UPDATE/i).first
        expect(sql).to include("allowed_roles = ARRAY[$3]::text[]")
        expect(binds).to eq([user_id, "agent-known", "owner"])
      end
    end
  end

  # End-to-end watermark ordering with the REAL RevocationStore + JwtIssuer:
  # a token minted BEFORE the rebind must stop verifying, while the fresh token
  # bind! returns must still verify. Proves the strict `iat < watermark` check
  # keeps the replacement token alive.
  describe ".bind! — known key rebind watermark ordering (real issuer)" do
    let(:agent_id)      { "agent-known" }
    let(:previous_user) { "22222222-2222-2222-2222-222222222222" }

    before do
      Kiosk.reset!
      Kiosk.configure do |c|
        c.signing_key = Kiosk::Server::SigningKey.generate
        c.issuer      = "https://demo.example"
        c.roles       = %i[customer]
        c.schema      = "kiosk"
      end
      # Un-stub issue (the outer before stubs it to a fixed string) so bind!
      # mints a REAL JWT; lookup_user_id (called inside issue) resolves the
      # rebound principal without a DB.
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:issue).and_call_original
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:lookup_user_id).and_return(user_id)
      route_exec_query(con) do |sql, _binds|
        if sql =~ /SELECT/i
          [{ "id" => agent_id, "user_id" => previous_user, "allowed_roles" => "{customer}" }]
        else
          []
        end
      end
      ar_base = class_double("ActiveRecord::Base").as_stubbed_const
      allow(ar_base).to receive(:lease_connection).and_return(con)
    end

    def verify(token)
      Kiosk::Server::JwtIssuer.verify(
        token:    token,
        jwks:     Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key]),
        audience: "https://demo.example",
        issuer:   "https://demo.example",
      )
    end

    it "revokes a pre-rebind token but leaves the fresh bind! token verifiable" do
      # A token minted BEFORE the rebind (iat in the past ⇒ strictly < watermark).
      prelink = Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: previous_user, agent_id: agent_id, role: "customer", actor: "agent" },
        audience: "https://demo.example",
        now:      Time.now - 10,
      )
      expect { verify(prelink) }.not_to raise_error # valid before the rebind

      result = described_class.bind!(public_key_pem: pem, user_id: user_id)
      fresh  = result.fetch(:access_token)

      # Pre-link token now covered by the watermark → RevokedError (→ 401).
      expect { verify(prelink) }.to raise_error(Kiosk::Server::JwtIssuer::RevokedError)
      # The fresh token returned by bind! survives (iat >= watermark).
      expect { verify(fresh) }.not_to raise_error
      expect(verify(fresh)[:sub]).to eq(user_id)
    end

    # K-836 — the same second-resolution aperture K-835 closed on `unlink`,
    # which was still open HERE, where §6.3 also says MUST ("the key's pre-link
    # tokens MUST stop verifying, watermark-revoked exactly as unlink revokes").
    # The example above only proves it for a token minted 10 seconds earlier;
    # the strict `iat < watermark` comparison let a pre-link token whose `iat`
    # EQUALS the rebind second keep working for its full remaining lifetime
    # (measured 3/3 on a booted philslist). Unlike unlink, this caller returns a
    # replacement token, which is why it cannot just pass `+1` and stop: the
    # replacement is minted AT the watermark so it survives its own revocation.
    it "revokes a pre-link token minted in the SAME wall-clock second as the rebind" do
      frozen = Time.at(Time.now.to_i)
      allow(Time).to receive(:now).and_return(frozen)

      prelink = Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: previous_user, agent_id: agent_id, role: "customer", actor: "agent" },
        audience: "https://demo.example",
      )
      expect { verify(prelink) }.not_to raise_error # valid before the rebind

      fresh = described_class.bind!(public_key_pem: pem, user_id: user_id).fetch(:access_token)

      expect { verify(prelink) }.to raise_error(Kiosk::Server::JwtIssuer::RevokedError)
      # …and the replacement the SAME call returns is still usable, which is the
      # constraint that rules out unlink's fix being copied here verbatim.
      expect { verify(fresh) }.not_to raise_error
      expect(verify(fresh)[:sub]).to eq(user_id)
    end

    it "stamps the watermark at the NEXT second and dates the replacement token at it" do
      now = Time.now.to_i
      allow(Time).to receive(:now).and_return(Time.at(now))

      fresh = described_class.bind!(public_key_pem: pem, user_id: user_id).fetch(:access_token)

      expect(Kiosk.configuration.revocation_store.watermark_for(agent_id)).to eq(now + 1)
      expect(verify(fresh)[:iat]).to eq(now + 1)
    end

    # §6.3 offers TWO ways back in after a rebind — the token the claim returns,
    # "or by re-running `/auth/login`" — and `kiosk-demo-tudu`'s link driver
    # takes the second one immediately. A `+1` watermark on its own would have
    # killed that login token for the rest of the same second (traded one
    # broken MUST for another), which is why the clamp lives in the IdP and not
    # in this caller: a token minted AFTER a revocation is never born revoked.
    it "leaves a /auth/login token minted in that same second alive" do
      now = Time.now.to_i
      allow(Time).to receive(:now).and_return(Time.at(now))

      described_class.bind!(public_key_pem: pem, user_id: user_id)
      relogin = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
                                                                     .issue(agent_id: agent_id, role: "customer")

      expect { verify(relogin) }.not_to raise_error
      expect(verify(relogin)[:iat]).to eq(now + 1)
    end
  end

  describe ".unlink!" do
    it "deactivates the binding (revoked_at) and watermark-revokes outstanding tokens" do
      route_exec_query(con) { [{ "id" => "agent-1" }] }
      expect(Kiosk.configuration.revocation_store)
        .to receive(:revoke_all).with("agent-1", hash_including(:at))

      result = described_class.unlink!(agent_id: "agent-1", user_id: user_id)
      expect(result).to eq(agent_id: "agent-1")

      sql, binds = con.bound(/UPDATE/i).first
      expect(sql).to include("SET revoked_at = now()")
      # The ownership predicate is this action's whole security story, and both
      # halves of it are binds: the caller supplies the agent id, the session
      # supplies the holder.
      expect(sql).to include("WHERE id = $1")
      expect(sql).to include("AND user_id = $2")
      expect(sql).to include("revoked_at IS NULL")
      expect(binds).to eq(["agent-1", user_id])
      expect(con).not_to have_received(:quote)
    end

    it "fires assistant_unlinked(agent:, user_id:)" do
      route_exec_query(con) { [{ "id" => "agent-1" }] }
      received = nil
      Kiosk.configure do |c|
        c.assistant_unlinked = ->(agent:, user_id:) { received = { agent: agent, user_id: user_id } }
      end

      described_class.unlink!(agent_id: "agent-1", user_id: user_id)
      expect(received).to eq(agent: "agent-1", user_id: user_id)
    end

    it "raises NotFound when the agent is not bound to this holder (or already unlinked)" do
      route_exec_query(con) { [] }
      expect {
        described_class.unlink!(agent_id: "someone-elses", user_id: user_id)
      }.to raise_error(Kiosk::Server::Errors::NotFound, /linked assistant account/)
    end

    it "rejects a blank agent_id" do
      expect { described_class.unlink!(agent_id: "", user_id: user_id) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /agent_id/)
    end

    # K-835. Spec §6.3/§15.4 promise that an unlinked key's tokens STOP
    # VERIFYING — with no "except one" attached. The store compares
    # `iat < watermark` on second-resolution JWT timestamps, so a watermark of
    # `Time.now.to_i` leaves the current second uncovered; because unlink also
    # 404s `/auth/login`, a token that slips through is the LAST one the key
    # will ever hold and it works for its full remaining lifetime (measured on
    # a booted philslist: read + write still 200 at +65s, token lifetime 3600s).
    # Unlink mints no replacement token, so it can and must cover the whole
    # second. The claim rebind passes the next second too since K-836 — it
    # returns a replacement, so it dates that token AT the watermark rather than
    # leaning on the strict `<`. `/auth/revoke` alone keeps `Time.now.to_i`, and
    # the reason is on RevocationStore: the caller holds the private key there.
    it "stamps the watermark at the NEXT second, so a same-second token is covered too" do
      route_exec_query(con) { [{ "id" => "agent-1" }] }
      now = Time.now.to_i
      allow(Time).to receive(:now).and_return(Time.at(now))
      stamped = nil
      allow(Kiosk.configuration.revocation_store)
        .to receive(:revoke_all) { |_agent, at:| stamped = at }

      described_class.unlink!(agent_id: "agent-1", user_id: user_id)

      expect(stamped).to eq(now + 1)
    end

    it "revokes a token minted in the same wall-clock second as the unlink" do
      route_exec_query(con) { [{ "id" => "agent-1" }] }
      store = Kiosk::Server::RevocationStore.new
      Kiosk.configure { |c| c.revocation_store = store }
      now = Time.now.to_i

      # The token the assistant is holding when the human clicks unlink.
      expect(store.revoked?(agent_id: "agent-1", iat: now)).to be(false)
      described_class.unlink!(agent_id: "agent-1", user_id: user_id)
      expect(store.revoked?(agent_id: "agent-1", iat: now)).to be(true)
    end
  end
end
