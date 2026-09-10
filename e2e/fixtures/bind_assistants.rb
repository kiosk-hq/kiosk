# frozen_string_literal: true

# Mint the two AGENT principals the e2e assistant suite runs as, by running the
# shipped ceremony against the booted origin — register (Equihash-tolled) ->
# the human's link code -> claim.
#
# NOTHING IN THIS TREE LETS A CALLER NAME AN IDENTITY RATHER THAN PROVE ONE,
# which is why the suite cannot simply write two principals down. The
# assertions downstream still run as "Alice's assistant" and "Bob's
# assistant"; the point is that the origin issued both tokens.
#
# The ceremony helper is the demos' single copy, reached rather than duplicated
# for the reason claim_flow.rb states about DeviseSession: an eighth copy of a
# mechanism is how the seventh one drifts.
#
# Prints ONE JSON line: {alice_agent, alice_token, bob_agent, bob_token}.
require_relative "../../kiosk-demo-stylish/script/bound_assistant"
require "json"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
PASSWORD = ENV.fetch("HUMAN_PASSWORD")

alice = bind_assistant(server: SERVER, issuer: ISSUER, email: "alice@example.com", password: PASSWORD)
bob   = bind_assistant(server: SERVER, issuer: ISSUER, email: "bob@example.com",   password: PASSWORD)

# The whole point of the ceremony is that the principal is the HUMAN's, so say
# so out loud rather than trusting it: a rebind remaps `agents.user_id`, and
# every isolation assertion downstream depends on these two being Alice and Bob.
{ "alice" => alice, "bob" => bob }.each do |name, a|
  claims = a.claims
  abort "#{name}: token actor is #{claims["actor"].inspect}, expected \"agent\"" unless claims["actor"] == "agent"
  abort "#{name}: bound to #{a.user_id}, which is not the seeded human" unless claims["sub"] == a.user_id
  abort "#{name}: agent_id #{a.agent_id.inspect} is not a uuid" unless
    a.agent_id =~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
end

puts JSON.generate(
  alice_agent: alice.agent_id, alice_token: alice.token, alice_user: alice.user_id,
  bob_agent:   bob.agent_id,   bob_token:   bob.token,   bob_user:   bob.user_id,
)
