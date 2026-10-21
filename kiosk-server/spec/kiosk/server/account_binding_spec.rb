# frozen_string_literal: true

require 'stringio'

# The binding product of the ceremonies: a registered client moves to the
# approving human's account, keeps its agent_id and reputation, and takes the
# human's role; unlink is the revocation of the registration. Against the
# shipped agents table.
module AccountBindingSpecHelpers
  # Rails.logger is nil in this plain-Ruby suite, so the line lands on $stderr.
  def capture_operator_log
    original = $stderr
    $stderr  = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  def issue(client = self.client) = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: client.id, role: client.role)

  def verified?(token)
    !Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new.verify('HTTP_AUTHORIZATION' => "DPoP #{token}").nil?
  end

  def roles_of(client) = Kiosk::Server::Client.find(client.id).allowed_roles
end

RSpec.describe Kiosk::Server::AccountBinding do
  include_context 'with registered clients'
  include AccountBindingSpecHelpers

  let(:client) { register_client }
  let(:holder) { holder! }

  def bind(user_id = holder, **) = described_class.bind!(agent_id: client.id, user_id: user_id, **)

  describe '.bind!' do
    it "moves the client to the holder's account, keeping its agent_id and key" do
      bound = bind(requested_role: 'owner')

      expect([bound.id, bound.user_id, bound.role]).to eq([client.id, holder, 'owner'])
      expect(bound.public_key_pem).to eq(client.public_key_pem)
    end

    it 'requires a user_id and a live client' do
      expect { bind(nil) }.to raise_error(ArgumentError, /user_id/)
      expect { described_class.bind!(agent_id: SecureRandom.uuid, user_id: holder) }.to raise_error(ArgumentError)
    end

    it 'never invokes the assistant_creation factory (the principal exists already)' do
      client
      factory = ->(_pem) { raise 'a binding must not create an account' }
      Kiosk.configure { |c| c.assistant_creation = factory }
      expect { bind(requested_role: 'customer') }.not_to raise_error
    end

    it 'refuses a role outside the declared set (no scope widening)' do
      expect { bind(requested_role: 'root') }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /root/)
      expect(Kiosk::Server::Client.find(client.id).user_id).to eq(client.user_id)
    end

    # The role the client had belonged to its previous holder, so a role-less
    # ceremony resets it to what registration would assign (K-1791).
    it 'resets a privileged role to registration_role when the ceremony carries none' do
      bind(holder!, requested_role: 'owner')
      capture_operator_log { expect(bind(requested_role: nil).role).to eq('customer') }
    end

    it 'writes the empty role set when the operator assigns no role at all' do
      client
      Kiosk.configure do |c|
        c.roles = []
        c.registration_role = nil
      end
      expect(bind.role).to be_nil
      expect(roles_of(client)).to eq([]).or eq('{}')
    end

    describe 'the assistant_claimed hook' do
      it 'fires with the previous and the new account, inside the rebind transaction' do
        fired = []
        Kiosk.configure { |c| c.assistant_claimed = ->(**kw) { fired << kw } }
        bind(requested_role: 'customer')

        expect(fired).to eq([{ agent: client.id, from: OauthClients::User.find(client.user_id),
                               to: OauthClients::User.find(holder) }])
      end

      it 'aborts the rebind when it raises' do
        Kiosk.configure { |c| c.assistant_claimed = ->(**) { raise 'host failure' } }
        expect { bind(requested_role: 'customer') }.to raise_error('host failure')
        expect(Kiosk::Server::Client.find(client.id).user_id).to eq(client.user_id)
      end

      # K-783: a re-bind to the same holder transitions nothing, and the
      # fleet's one hook deletes the memberships of `from`.
      it 'does not fire for a rebind to the same holder, compared by value' do
        bind(requested_role: 'customer')
        fired = []
        Kiosk.configure { |c| c.assistant_claimed = ->(**kw) { fired << kw } }
        bind(holder.dup, requested_role: 'owner')

        expect(fired).to be_empty
        expect(roles_of(client)).to eq(['owner']).or eq('{owner}')
      end
    end

    describe 'the misconfiguration warning (T-165)' do
      it 'warns the operator when a role-less ceremony lands on a multi-role origin' do
        client
        output = capture_operator_log { bind(requested_role: nil) }

        expect(output).to include('resolved NO role for the approving human', 'must be TOTAL', 'kiosk_role',
                                  'lands on :customer', 'owner')
      end

      it 'prefers Rails.logger when a Rails logger is present' do
        client
        logger = instance_double(Logger, warn: nil)
        allow(Rails).to receive(:logger).and_return(logger)
        bind(requested_role: nil)
        expect(logger).to have_received(:warn).with(/resolved NO role for the approving human/).once
      end

      it 'stays silent on a single-role origin, and when the ceremony carries a role' do
        client
        expect(capture_operator_log { bind(requested_role: 'owner') }).to eq('')
        Kiosk.configure { |c| c.roles = %i[customer] }
        expect(capture_operator_log { bind(requested_role: nil) }).to eq('')
      end
    end

    describe 'the revocation watermark (§6.3)' do
      it 'revokes every earlier token, also one minted in the same second, and the next token verifies' do
        earlier = issue
        bound = bind(requested_role: 'customer')

        expect(verified?(earlier)).to be(false)
        expect(verified?(issue(bound))).to be(true)
      end

      it 'stamps the watermark after now, also for a rebind to the same holder' do
        bind(requested_role: 'customer')
        stamped = Kiosk.configuration.revocation_store.watermark_for(client.id)
        expect(stamped).to be > Time.now.to_i - 1

        earlier = issue
        bind(requested_role: 'customer')
        expect(verified?(earlier)).to be(false)
      end
    end
  end

  describe '.unlink!' do
    let!(:bound) { bind(requested_role: 'customer') }

    it 'deactivates the client and revokes its tokens, also one minted in the same second' do
      token = issue(bound)
      described_class.unlink!(agent_id: client.id, user_id: holder)

      expect(Kiosk::Server::Client.find(client.id)).to be_nil
      expect(verified?(token)).to be(false)
    end

    it 'fires assistant_unlinked(agent:, account:) with the account' do
      fired = []
      Kiosk.configure { |c| c.assistant_unlinked = ->(**kw) { fired << kw } }
      described_class.unlink!(agent_id: client.id, user_id: holder)
      expect(fired).to eq([{ agent: client.id, account: OauthClients::User.find(holder) }])
    end

    it 'refuses a client of another holder, an unlinked client and a blank agent_id' do
      expect { described_class.unlink!(agent_id: client.id, user_id: holder!) }
        .to raise_error(Kiosk::Server::Errors::NotFound)
      described_class.unlink!(agent_id: client.id, user_id: holder)
      expect { described_class.unlink!(agent_id: client.id, user_id: holder) }
        .to raise_error(Kiosk::Server::Errors::NotFound)
      expect { described_class.unlink!(agent_id: '', user_id: holder) }
        .to raise_error(Kiosk::Server::Errors::BadRequest)
    end
  end
end
