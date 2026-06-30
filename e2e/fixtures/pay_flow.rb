# frozen_string_literal: true

# No-human payment proof. The agent generates its own keypair, SELF-REGISTERS
# a synthetic principal (no human, no device-grant), signs an AP2 intent+cart
# mandate bound to that principal, and pays. Prints a JSON line on stdout.
require "jwt"; require "json"; require "net/http"; require "uri"; require "openssl"; require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

key = OpenSSL::PKey::RSA.generate(2048)
rc, reg = post_json("#{SERVER}/kiosk/agents/register",
  { name: "e2e-agent", public_key: key.public_key.to_pem, role: "customer" })
abort "register failed: #{rc} #{reg}" unless rc == 201
agent_id = reg.fetch("agent_id"); user_id = reg.fetch("user_id"); token = reg.fetch("access_token")

now = Time.now.to_i
intent_id = SecureRandom.uuid
cap_amount_cents = 2000
total_amount_cents = ENV["CART_OVER_CAP"] ? cap_amount_cents + 1 : 1599
intent = { id: intent_id, user_id: user_id, agent_id: agent_id, iss: ISSUER,
           scope: "food", cap_amount_cents: cap_amount_cents, currency: "eur", exp: now + 600, iat: now }
cart_id = SecureRandom.uuid
cart = { id: cart_id, intent_mandate_id: intent_id, user_id: user_id, agent_id: agent_id,
         iss: ISSUER, line_items: [{ sku: "pizza", qty: 1 }], total_amount_cents: total_amount_cents,
         currency: "eur", exp: now + 600, iat: now }
payment_id = SecureRandom.uuid
payment = { id: payment_id, cart_mandate_id: cart_id, user_id: user_id, agent_id: agent_id,
            iss: ISSUER, payment_method: "pm_demo", amount_cents: total_amount_cents,
            currency: "eur", exp: now + 600, iat: now }

rc, pay = post_json("#{SERVER}/kiosk/exec",
  { command: "pay", body: { intent_mandate_jws: JWT.encode(intent, key, "RS256"),
                            cart_mandate_jws:   JWT.encode(cart, key, "RS256"),
                            payment_mandate_jws: JWT.encode(payment, key, "RS256") } },
  { "Authorization" => "Bearer #{token}" })

puts JSON.generate(http_code: rc, user_id: user_id, agent_id: agent_id, response: pay)
