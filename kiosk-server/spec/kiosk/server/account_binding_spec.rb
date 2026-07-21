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
    allow(ar_base).to receive(:connection).and_return(con)
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:issue).and_return("kiosk-pop-jwt")
  end

  describe ".bind! — fresh key" do
    before do
      # SELECT finds no live agent; INSERT returns the new id.
      allow(con).to receive(:execute) do |sql|
        con.executed_sql << sql
        sql =~ /INSERT/i ? [{ "id" => "agent-new" }] : []
      end
    end

    it "registers a linked assistant account under the holder's user_id" do
      result = described_class.bind!(public_key_pem: pem, user_id: user_id)

      expect(result).to eq(
        agent_id: "agent-new", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: true,
      )
      insert = con.executed_sql.grep(/INSERT/i).first
      expect(insert).to include("'#{user_id}'")
      expect(insert).to include("kiosk.agents")
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
      expect(con.executed_sql.grep(/INSERT/i).first).to include("ARRAY['customer']::text[]")
    end

    it "falls back to registration_role, and NULL when neither is set" do
      described_class.bind!(public_key_pem: pem, user_id: user_id)
      expect(con.executed_sql.grep(/INSERT/i).first).to include("NULL")

      Kiosk.configure { |c| c.registration_role = :customer }
      described_class.bind!(public_key_pem: pem, user_id: user_id)
      expect(con.executed_sql.grep(/INSERT/i).last).to include("ARRAY['customer']::text[]")
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
      allow(con).to receive(:execute) do |sql|
        con.executed_sql << sql
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
      update = con.executed_sql.grep(/UPDATE/i).first
      expect(update).to include("SET user_id = '#{user_id}'")
      expect(con.executed_sql.grep(/INSERT/i)).to be_empty
      # Reputation carry-over = the binding touches ONLY agents.user_id.
      expect(con.executed_sql.join).not_to match(/reputation|allowed_roles\s*=/i)
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

        update = con.executed_sql.grep(/UPDATE/i).first
        expect(update).to include("SET user_id = '#{user_id}'")
        expect(update).to include("allowed_roles = ARRAY['owner']::text[]")
        expect(con.executed_sql.grep(/INSERT/i)).to be_empty # still a rebind
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
      expect(con.executed_sql.join).not_to match(/allowed_roles\s*=/i)
    end

    # A rebind is a principal change, so — like
    # unlink! — it watermark-revokes the key's pre-link tokens.
    it "watermark-revokes the key's pre-link tokens (principal change ⇒ re-login)" do
      expect(Kiosk.configuration.revocation_store)
        .to receive(:revoke_all).with("agent-known", hash_including(:at))

      described_class.bind!(public_key_pem: pem, user_id: user_id)
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
      allow(con).to receive(:execute) do |sql|
        con.executed_sql << sql
        if sql =~ /SELECT/i
          [{ "id" => agent_id, "user_id" => previous_user, "allowed_roles" => "{customer}" }]
        else
          []
        end
      end
      ar_base = class_double("ActiveRecord::Base").as_stubbed_const
      allow(ar_base).to receive(:connection).and_return(con)
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
  end

  describe ".unlink!" do
    it "deactivates the binding (revoked_at) and watermark-revokes outstanding tokens" do
      allow(con).to receive(:execute) do |sql|
        con.executed_sql << sql
        [{ "id" => "agent-1" }]
      end
      expect(Kiosk.configuration.revocation_store)
        .to receive(:revoke_all).with("agent-1", hash_including(:at))

      result = described_class.unlink!(agent_id: "agent-1", user_id: user_id)
      expect(result).to eq(agent_id: "agent-1")

      update = con.executed_sql.grep(/UPDATE/i).first
      expect(update).to include("SET revoked_at = now()")
      expect(update).to include("user_id = '#{user_id}'") # only the holder's own
      expect(update).to include("revoked_at IS NULL")
    end

    it "fires assistant_unlinked(agent:, user_id:)" do
      allow(con).to receive(:execute).and_return([{ "id" => "agent-1" }])
      received = nil
      Kiosk.configure do |c|
        c.assistant_unlinked = ->(agent:, user_id:) { received = { agent: agent, user_id: user_id } }
      end

      described_class.unlink!(agent_id: "agent-1", user_id: user_id)
      expect(received).to eq(agent: "agent-1", user_id: user_id)
    end

    it "raises NotFound when the agent is not bound to this holder (or already unlinked)" do
      allow(con).to receive(:execute).and_return([])
      expect {
        described_class.unlink!(agent_id: "someone-elses", user_id: user_id)
      }.to raise_error(Kiosk::Server::Errors::NotFound, /linked assistant account/)
    end

    it "rejects a blank agent_id" do
      expect { described_class.unlink!(agent_id: "", user_id: user_id) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /agent_id/)
    end
  end
end
