# frozen_string_literal: true

# Shared registration helper for the e2e flows: RFC 7591 registration of a key,
# RFC 7523 client assertions, and the client_credentials token request.
#
# Registration is gated by Equihash proofs; this helper takes their count and
# params off the 402 it is answering. On a 402 pow_required it solves every
# challenge with the shipped Python solver and sends the SAME registration body
# again, with the proof(s) in the Kiosk-PoW request header as raw JSON.
#
# Requires the caller's own `post_json(url, body, headers)`, which returns
# `[code, body]`.
#
# The generated app bundles kiosk-pow-equihash, and that gem owns solve.py and
# knows where it is inside its own package — so nothing here, and nothing in
# run.sh, has to carry a path to it.

require 'json'
require 'jwt'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'uri'
require 'kiosk/pow/equihash/solver'
require 'kiosk/test_helpers/dpop'
require 'kiosk/test_helpers/wire'

ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'

# Solve one Equihash challenge with the solver kiosk-pow-equihash ships.
def equihash_solve(challenge)
  Kiosk::Pow::Equihash.solve(challenge)
rescue Kiosk::Pow::Equihash::SolverError => e
  abort e.message
end

# The registration body of `key`: its public JWK in a JWK Set (RFC 7591).
def registration_body(key) = { jwks: { keys: [Kiosk::TestHelpers::Dpop.jwk(key)] } }

# Register a key at the Equihash-gated /oauth/register.
#
# @param server   [String]  base URL (e.g. http://127.0.0.1:3001)
# @param headers  [Hash]    sent on every request (e.g. a Host for a second origin)
# @param on_proofs [#call, nil] called with the proofs this helper sent, once the server accepted them
# @param key [OpenSSL::PKey::RSA] the keypair to register; a fresh one by default
# @return [Array(OpenSSL::PKey::RSA, Hash)] the keypair and the 201 client information
def equihash_register(server:, headers: {}, on_proofs: nil, key: OpenSSL::PKey::RSA.generate(2048))
  body = registration_body(key)
  rc, reg = post_json("#{server}/kiosk/oauth/register", body, headers)
  rc, reg = pay_registration_toll(server, body, reg, headers, on_proofs) if rc == 402

  abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  [key, reg]
end

# Solves every challenge of the 402 and sends the SAME body again.
# RFC 9457: `challenges` is a top-level member.
def pay_registration_toll(server, body, problem, headers, on_proofs)
  challenges = problem['challenges']
  abort "402 without challenges[]: #{JSON.generate(problem)}" unless challenges.is_a?(Array) && challenges.any?

  proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
  rc, reg = post_json("#{server}/kiosk/oauth/register", body, headers.merge('Kiosk-PoW' => JSON.generate(proofs)))
  # Only proofs the server accepted say anything about the shape it requires.
  on_proofs&.call(proofs) if rc == 201
  [rc, reg]
end

# A client assertion (RFC 7523) that `key` signs for `client_id`. `aud` is the
# origin the caller dials. `claims` adds members, such as a rotation's `new_key`.
def client_assertion(client_id, key, issuer, **claims)
  now = Time.now.to_i
  JWT.encode({ iss: client_id, sub: client_id, aud: issuer, jti: SecureRandom.uuid, iat: now, exp: now + 60, **claims },
             key, 'RS256', { typ: 'client-authentication+jwt' })
end

# The two members that authenticate a client.
def assertion_params(client_id, key, issuer)
  { 'client_assertion_type' => ASSERTION_TYPE, 'client_assertion' => client_assertion(client_id, key, issuer) }
end

# POSTs a form to the token endpoint, with a DPoP proof of `key` that names no
# token. `htu` is the token endpoint of `issuer`; `headers` reach the same
# server under the Host of another origin.
# @return [Array(Integer, Hash)]
def token_request(server:, issuer:, key:, form:, headers: {})
  uri = URI("#{server}/kiosk/oauth/token")
  proof = Kiosk::TestHelpers::Dpop.headers(nil, key, method: 'POST', url: "#{issuer}/kiosk/oauth/token")
  req = Net::HTTP::Post.new(uri, headers.merge(proof))
  req.set_form_data(form)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, begin
    JSON.parse(res.body)
  rescue StandardError
    {}
  end]
end

# The client_credentials grant for a registered client.
# @return [Array(Integer, Hash)]
def client_token(server:, issuer:, client_id:, key:, headers: {})
  form = { 'grant_type' => 'client_credentials', **assertion_params(client_id, key, issuer) }
  token_request(server:, issuer:, key:, form:, headers:)
end

# Registers a fresh key and gets its first token; aborts on any failure.
# @return [Array(OpenSSL::PKey::RSA, Hash, String)] the keypair, the client information and the access token
def register_with_token(server:, issuer:, **)
  key, reg = equihash_register(server:, **)
  rc, tok = client_token(server:, issuer:, client_id: reg.fetch('client_id'), key:)
  abort "token request failed (#{rc}): #{JSON.generate(tok)}" unless rc == 200
  [key, reg, tok.fetch('access_token')]
end
