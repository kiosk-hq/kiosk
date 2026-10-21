# frozen_string_literal: true

# Mint the two AGENT principals the e2e assistant suite runs as: each human
# signs in on the site, mints a link code, and a newly keyed assistant claims it.
#
# Writes each assistant's private key to KEY_DIR, mode 600: the key signs the
# DPoP proof of every call its token makes. Prints ONE JSON line:
# {alice_agent, alice_token, alice_user, alice_key, bob_agent, bob_token, bob_user, bob_key}.
require 'json'
require 'kiosk/test_helpers/person'

SERVER   = ENV.fetch('SERVER_URL')
PASSWORD = ENV.fetch('HUMAN_PASSWORD')
KEY_DIR  = ENV.fetch('KEY_DIR')

alice = Kiosk::TestHelpers::Person.new(SERVER, email: ENV.fetch('ALICE_EMAIL'), password: PASSWORD).links_a_newcomer
bob   = Kiosk::TestHelpers::Person.new(SERVER, email: ENV.fetch('BOB_EMAIL'),   password: PASSWORD).links_a_newcomer

# Every isolation assertion downstream depends on these two being Alice's and Bob's.
{ 'alice' => alice, 'bob' => bob }.each do |name, a|
  abort "#{name}: token actor is #{a.claims['actor'].inspect}, expected \"agent\"" unless a.claims['actor'] == 'agent'
  abort "#{name}: agent_id #{a.principal.agent_id.inspect} is not a uuid" unless
    a.principal.agent_id =~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
end

key_file = lambda do |name, a|
  File.join(KEY_DIR, "#{name}.pem").tap do |path|
    File.write(path, a.principal.rsa_key.to_pem)
    File.chmod(0o600, path)
  end
end

puts JSON.generate(
  alice_agent: alice.principal.agent_id, alice_token: alice.principal.token, alice_user: alice.principal.user_id,
  alice_key: key_file.call('alice', alice),
  bob_agent: bob.principal.agent_id, bob_token: bob.principal.token, bob_user: bob.principal.user_id,
  bob_key: key_file.call('bob', bob)
)
