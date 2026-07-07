# frozen_string_literal: true

# GET /kiosk/help — unauthenticated agent bootstrap. An assistant that found the
# hook on the homepage (or /.well-known/kiosk.json) reads this once and has
# everything to transact: the protocol handshake (register / verbs / AP2 pay /
# PoW) PLUS this provider's live surface (queries + actions, from the registry).
#
# This is intentionally provider-agnostic protocol text + a live surface dump.
# A follow-up moves the generic part into kiosk-server so every provider serves
# the same bootstrap automatically.
class KioskHelpController < ActionController::Base
  def show
    render plain: bootstrap, content_type: "text/markdown"
  end

  private

  def bootstrap
    issuer = Kiosk.configuration.issuer
    <<~MD
      # #{Kiosk.configuration.owner&.fetch(:name, "this provider") rescue "this provider"} — Kiosk agent guide

      This provider speaks **Kiosk**. Your AI assistant can browse, order, pay, and
      schedule delivery directly — no human account, no human checkout. Everything
      below is the whole protocol; the surface in section 3 is live.

      ## 1. Discover
      `GET /.well-known/kiosk.json` → `issuer`, `endpoint`, and `routing` (verb → method + path).
      This provider's issuer is `#{issuer}`.

      ## 2. Register / login (prove you hold the private key)
      Generate an RSA-2048 keypair; keep the private key. Registration is a
      proof-of-possession handshake (a public key alone is not a credential):
      1. `GET /kiosk/auth/challenge?public_key=<url-encoded PEM>` → `{ challenge, exp }`
      2. Sign a compact RS256 JWS `{ aud, nonce, jti, iat }` — `aud` MUST be the
         origin you connected to (relay defense), `nonce` is the challenge.
      3. New key: `POST /kiosk/auth/register { "public_key": "<PEM>", "signed": "<JWS>" }`
         → `{ agent_id, user_id, access_token }`. Known key: `POST /kiosk/auth/login`
         (same body) → `{ access_token }`. Send `Authorization: Bearer ***` on every call below.

      ## 3. Call the surface
      REST endpoints (one per verb, HTTP method = semantics):

      - `GET  <endpoint>/schema` — machine-readable surface (queries + actions + params)
      - `POST <endpoint>/query  { "name": <name>, ...params }` — read data
      - `POST <endpoint>/run    { "name": <name>, ...params }` — perform action
      - `POST <endpoint>/pay    { "intent_mandate_jws": …, "cart_mandate_jws": …, "payment_mandate_jws": … }` — settle payment

      Legacy `POST /exec { "command": <verb>, "body": {…} }` still works for backward compatibility.

      ### Queries — `POST /query { "name": … }`
      #{describe(Kiosk::Server::Queries)}

      ### Actions — `POST /run { "name": … }`
      #{describe(Kiosk::Server::Actions)}

      ## 4. Pay (AP2 mandates)
      Sign three **RS256 JWS** with your keypair, `iss` = `#{issuer}`:
      - **intent**: `{ id, user_id, agent_id, iss, scope, cap_amount_cents, currency, exp, iat }`
      - **cart**: `{ id, intent_mandate_id, user_id, agent_id, iss, line_items:[…], total_amount_cents, currency, exp, iat }`
      - **payment**: `{ id, cart_mandate_id, user_id, agent_id, iss, payment_method, amount_cents, currency, exp, iat }`
      Then `POST <endpoint>/pay { "intent_mandate_jws": …, "cart_mandate_jws": …, "payment_mandate_jws": … }`.
      Bind all mandates to your registered `user_id`/`agent_id`; `iss` must equal the issuer above.

      ## 5. Notes
      - If any call returns HTTP 402 `pow_required`, solve the proof-of-work in the
        challenge and retry the same request with a top-level `pow` field.
      - You can always re-derive section 3 at runtime: `query`-less `{ "command":"schema" }`
        returns the machine-readable surface, `{ "command":"help" }` the human-readable one.
    MD
  end

  # Enumerate a registry's entries (name + description + param hints) from the
  # live Queries/Actions catalog.
  def describe(registry)
    entries = registry.respond_to?(:catalog) ? registry.catalog : registry.known.map { |n| { name: n } }
    return "_(none registered)_" if entries.empty?

    entries.map { |e|
      e = e.transform_keys(&:to_sym) if e.respond_to?(:transform_keys)
      name   = e[:name]
      desc   = e[:description]
      params = e[:params]
      pstr   = params.is_a?(Hash) && !params.empty? ? " · params: #{params.keys.join(", ")}" : ""
      "- **#{name}** — #{desc || "—"}#{pstr}"
    }.join("\n")
  rescue StandardError
    registry.known.map { |n| "- **#{n}**" }.join("\n")
  end
end
