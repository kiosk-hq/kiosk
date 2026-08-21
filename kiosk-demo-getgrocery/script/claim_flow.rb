# frozen_string_literal: true

# Agent-side driver: the claim-rebind walkthrough ("why not MY account?").
#
# Beat 1 — standalone: the assistant self-registers (kiosk-pop, fresh key,
#   its own synthetic account) and places a grocery order there.
# Beat 2 — the human says "use MY account": the assistant opens the claim
#   ceremony with its EXISTING key; the human signs in at /users/sign_in and
#   approves on the verify page over that REAL Devise session; the
#   possession-proof poll re-binds the key: agent_id stays, user_id remaps to
#   the human's,
#   reputation carries. The old standalone order is NOT migrated — domain
#   rows belong to the provider, and this provider configures no
#   assistant_claimed hook.
# Beat 3 — the assistant places a NEW order as the human and pays with the
#   human's saved card (the seeded stripe_customers mapping; stripe-mock
#   serves the card fixture, so no real charge). No KIOSK_TEST_AUTOCARD
#   shortcut here: the standalone account genuinely gets `setup_required`
#   (no card on file), the claimed account genuinely gets `ready` — the
#   contrast IS the point of claiming.
#
# Usage (invoked by rake demo:claim):
#   SERVER_URL=… KIOSK_ISSUER=… HUMAN_USER_ID=… HUMAN_EMAIL=… HUMAN_PASSWORD=… \
#   bundle exec ruby script/claim_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any hard failure.

require "date"
require "jwt"
require "json"
require "net/http"
require "uri"
require "openssl"
require "securerandom"
require "base64"

require_relative "devise_session"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
HUMAN    = ENV.fetch("HUMAN_USER_ID")   # seeded account holder with a saved card
EMAIL    = ENV.fetch("HUMAN_EMAIL")
PASSWORD = ENV.fetch("HUMAN_PASSWORD")

# The human's browser session — the REAL one. getgrocery used to hand the
# verify page a self-asserted `user:u-<uuid>` bearer because it shipped no login
# UI; it ships one now (T-066), so the approving human is a Devise/Warden
# session like every other demo's, and this driver holds it the way a browser
# does. The agent's calls below never touch it.
HUMAN_SESSION = DeviseSession.new(SERVER)

# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING; an action is `POST <endpoint>/<action-name>` with its
# arguments as the JSON BODY. There is no `name` field and no /query or /run
# endpoint. A success body IS the result, and `pay` answers the settlement
# object itself; an error is an RFC 9457 problem document whose branch point is
# the TOP-LEVEL `code`.
def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {}, params = {})
  uri = URI(url)
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def post_form(url, form, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, headers)
  req.set_form_data(form)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, res, (JSON.parse(res.body) rescue {})]
end

# Fresh possession proof (same challenge-response JWS as register/login).
def pop_proof(key, pem)
  rc, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

def jwt_claims(token)
  seg = token.split(".")[1]
  JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
end

def create_order(token, items)
  # Delivery is part of the order: slot + address are required fields.
  rc, resp = post_json("#{SERVER}/kiosk/create_order",
                       { items: items,
                         delivery_slot_id: 1, delivery_address: "7 Claim Ct, Dublin 8" },
                       { "Authorization" => "Bearer #{token}" })
  abort "create_order failed (#{rc}): #{JSON.generate(resp)}" unless rc == 200
  # Carry the server's EUR display string so operator stdout shows €, not cents.
  [resp["order_id"], resp["total_cents"], resp["total_eur"]]
end

results = {}

# ── Beat 1: standalone — register a fresh key, order groceries ──────────────
# The register PoW is solved transparently by the helper; the SAME private key
# is returned so the claim ceremony (Beat 2) and the payment mandates below can
# re-prove possession / sign with it.
require_relative "equihash_register"
key, reg, rc_register = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)
pem = key.public_key.to_pem
results[:http_register]  = rc_register
agent_id                 = reg.fetch("agent_id")
standalone_user_id       = reg.fetch("user_id")
token                    = reg.fetch("access_token")
results[:standalone_user_id] = standalone_user_id
STDERR.puts "  Standalone: registered agent_id=#{agent_id} user_id=#{standalone_user_id}"

rc, cat = get_json("#{SERVER}/kiosk/catalog", { "Authorization" => "Bearer #{token}" })
abort "catalog failed (#{rc})" unless rc == 200
chosen = Array(cat).first(2)
items  = chosen.map { |p| { sku: p.fetch("sku"), qty: 1 } }
mirror = chosen.map { |p| { sku: p.fetch("sku"), qty: 1, price_cents: p.fetch("price_cents").to_i } }
standalone_order_id, = create_order(token, items)
results[:standalone_order_id] = standalone_order_id
STDERR.puts "  Standalone: ordered #{items.map { |i| i[:sku] }.join(", ")} (order #{standalone_order_id})"

# The standalone account has no card on file — paying would first send the
# human to Stripe's hosted card-entry page.
rc, setup = post_json("#{SERVER}/kiosk/payment_setup", {}, { "Authorization" => "Bearer #{token}" })
results[:standalone_payment_setup] = [rc, setup["status"]]
STDERR.puts "  Standalone: payment_setup → #{setup["status"]} (no saved card)"

# ── Beat 2: "use MY account" — claim ceremony with the EXISTING key ─────────
rc, da = post_json("#{SERVER}/kiosk/oauth/device_authorization",
                   { client_id: "getgrocery-claim-demo", public_key: pem })
abort "device_authorization failed (#{rc}): #{JSON.generate(da)}" unless rc == 200
results[:da_fields] = %w[device_code user_code verification_uri expires_in interval].all? { |k| da.key?(k) }
device_code = da.fetch("device_code")
user_code   = da.fetch("user_code")
STDERR.puts "  Claim opened for the SAME key: user_code=#{user_code}"

# The human signs in through the REAL Devise form first — no fixtures, no
# in-process shortcut — and only then can she see the verify page at all.
HUMAN_SESSION.sign_in!(email: EMAIL, password: PASSWORD)
results[:human_signed_in] = true
STDERR.puts "  Human signed in via /users/sign_in (Devise session cookie held)"

# She approves on the verify page: GET first (the page + its CSRF token), then
# POST the decision over the same session.
show = HUMAN_SESSION.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
abort "verify page: #{show.code}" unless show.code.to_i == 200
form = { "user_code" => user_code, "decision" => "approve" }
if (csrf = HUMAN_SESSION.csrf_token(show.body))
  form["authenticity_token"] = csrf
end
approve = HUMAN_SESSION.post_form("/kiosk/oauth/device/verify", form)
rc = approve.code.to_i
results[:approve] = rc
STDERR.puts "  Human approved on the verify page (#{rc})"

# Possession-proof token poll (pacing: the registry counts every poll).
sleep(da.fetch("interval", 5) + 1)
rc, _res, tok = post_form("#{SERVER}/kiosk/oauth/token",
                          { grant_type: "urn:ietf:params:oauth:grant-type:device_code",
                            device_code: device_code, signed: pop_proof(key, pem) })
abort "token poll failed (#{rc}): #{JSON.generate(tok)}" unless rc == 200
human_token = tok.fetch("access_token")
claims      = jwt_claims(human_token)
results[:agent_id_stable] = claims["agent_id"] == agent_id
results[:rebound_user]    = claims["sub"] == HUMAN
results[:agent_id]        = agent_id
STDERR.puts "  Rebind: agent_id=#{claims["agent_id"]} (stable) user_id=#{claims["sub"]} (the human)"

# The standalone order stayed with the standalone account — domain rows are
# not auto-migrated. The human's my_orders must not contain it.
rc, mine = get_json("#{SERVER}/kiosk/my_orders", { "Authorization" => "Bearer #{human_token}" })
abort "my_orders failed (#{rc})" unless rc == 200
results[:standalone_order_not_migrated] = Array(mine).none? { |o| o["order_id"] == standalone_order_id }

# ── Beat 3: a NEW order as the human, paid with the saved card ──────────────
new_order_id, total_cents, total_eur = create_order(human_token, items)
results[:new_order_id] = new_order_id

# The human's account HAS a card on file (the seeded mapping) — ready.
rc, setup = post_json("#{SERVER}/kiosk/payment_setup", {}, { "Authorization" => "Bearer #{human_token}" })
results[:human_payment_setup] = [rc, setup["status"]]
STDERR.puts "  As the human: payment_setup → #{setup["status"]} (saved card on file)"

now = Time.now.to_i
intent_payload = {
  id: SecureRandom.uuid, user_id: HUMAN, agent_id: agent_id, iss: ISSUER,
  scope: "grocery", cap_amount_cents: total_cents + 200, currency: "eur",
  exp: now + 600, iat: now,
}
cart_payload = {
  id: SecureRandom.uuid, intent_mandate_id: intent_payload[:id], user_id: HUMAN,
  agent_id: agent_id, iss: ISSUER,
  line_items: [{ order_id: new_order_id }] + mirror,
  total_amount_cents: total_cents, currency: "eur", exp: now + 600, iat: now,
}
payment_payload = {
  id: SecureRandom.uuid, cart_mandate_id: cart_payload[:id], user_id: HUMAN,
  agent_id: agent_id, iss: ISSUER,
  # No payment_method: SetupIntent model — the provider resolves the
  # account's on-file card; the assistant never presents one.
  amount_cents: total_cents, currency: "eur", exp: now + 600, iat: now,
}
rc, pay = post_json("#{SERVER}/kiosk/pay",
                    { intent_mandate_jws:  JWT.encode(intent_payload,  key, "RS256"),
                      cart_mandate_jws:    JWT.encode(cart_payload,    key, "RS256"),
                      payment_mandate_jws: JWT.encode(payment_payload, key, "RS256") },
                    { "Authorization" => "Bearer #{human_token}" })
abort "pay failed (#{rc}): #{JSON.generate(pay)}" unless rc == 200
results[:http_pay]      = rc
# `pay`'s success body IS the settlement object — no `value` to unwrap.
results[:psp_reference] = pay["psp_reference"].to_s
STDERR.puts "  Paid #{total_eur} with the human's saved card: #{results[:psp_reference]}"

# The new order is on the human's account now.
rc, mine = get_json("#{SERVER}/kiosk/my_orders", { "Authorization" => "Bearer #{human_token}" })
results[:human_sees_new_order] = rc == 200 && Array(mine).any? { |o| o["order_id"] == new_order_id }

puts JSON.generate(results)
