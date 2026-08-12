# frozen_string_literal: true

require "uri"

# OperatorRegistry — the broker's intake trust model (design §4.7). The broker only
# serves operators it has been configured with. This is what refuses arbitrary
# callers and arbitrary callback_urls (the SSRF / open-relay guard §4.7): the
# broker NEVER POSTs a callback to a URL a caller supplied free-form — it POSTs
# only to a pre-registered operator's callback host, and only when the caller
# presents that operator's shared bearer secret.
#
# For the demo, two operators are pre-registered here: skooti (motorcycle
# licence + age gate) and getgrocery (alcohol age gate). Each entry pins:
#   secret        — the shared bearer secret the operator sends on intake
#                   (Authorization: Bearer <secret>). Authenticates the operator.
#   callback_host — the ONLY host the broker will POST a callback to for this
#                   operator (host allow-list — an SSRF guard). The intake's
#                   callback_url must resolve to this host or the request is
#                   rejected. In the demo the operator host varies by port, so
#                   the callback host is configured per environment
#                   (KIOSK_PROVE_<OP>_CALLBACK_HOST, read in
#                   config/environments/*.rb — K-672).
#   audience      — the operator-binding `aud` the broker mints into this
#                   operator's attestations (the value its engine KycVerifier
#                   compares against its own kyc_audience). This is held at
#                   REGISTRATION, NOT taken from the intake body (K-550): the `aud`
#                   is derived from the authenticated operator's own record, so an
#                   operator can only ever obtain an attestation bound to ITS OWN
#                   audience — operator B cannot request operator A's audience.
#                   Defaults to the operator_id handle (what the demo operators set
#                   as c.kyc_audience); overridable for a distinct origin-URL
#                   audience via KIOSK_PROVE_<OP>_AUDIENCE (kept in lockstep with
#                   the operator's own kyc_audience so the honest bind-and-verify
#                   at intake matches).
#
# Production shape: OAuth client-credentials / mTLS instead of a shared secret,
# and a registration handshake instead of a static table (design §8.1 / Q1).
module OperatorRegistry
  module_function

  # Return the registered operator config for the given operator_id + presented
  # secret, or nil if the operator is unknown or the secret does not match.
  def authenticate(operator_id:, secret:)
    entry = registry[operator_id.to_s]
    return nil if entry.nil?
    return nil unless secure_compare(entry[:secret], secret.to_s)

    entry
  end

  # True when the given callback_url targets the operator's pre-registered
  # callback host (the SSRF / open-relay guard — §4.7). A caller cannot make the
  # broker POST to an arbitrary host.
  def callback_allowed?(operator, callback_url)
    return false if callback_url.to_s.empty?

    uri = begin
      URI.parse(callback_url.to_s)
    rescue URI::InvalidURIError
      return false
    end
    return false unless %w[http https].include?(uri.scheme)
    return false if uri.host.nil? || uri.host.empty?

    uri.host == operator[:callback_host]
  end

  # The demo registry, built from Rails custom config — the env vars behind
  # these values are read in config/environments/{development,test,production}.rb
  # and published as Rails.configuration.x.prove.* (K-672); this lib never
  # reads ENV, and each environment's posture lives in that environment's file:
  #   - secret: shared bearer. An operator with NO configured secret is simply
  #     NOT registered (fail-closed, K-547: a shipped default is world-readable
  #     in this public repo, so anyone could present it to drive operator intake
  #     and trigger broker→operator callbacks) — `authenticate` then rejects it
  #     rather than honouring a guessable token. Production and development are
  #     both env-or-nothing (the two-server harnesses pin the secret explicitly
  #     on both sides — since K-650 there is no operator-side dev default to
  #     pair with); test registers both demo operators with fixture literals
  #     because the request specs drive real intake auth.
  #   - callback_host: the operator host the broker may call back (SSRF guard);
  #     set by the two-server harness (which knows the operator's host:port),
  #     loopback in dev/test, deploy-set in production.
  def registry
    cfg = Rails.configuration.x.prove
    entries = {}
    if (skooti = cfg.skooti_secret.presence)
      entries["skooti"] = {
        secret:        skooti,
        callback_host: cfg.skooti_callback_host,
        audience:      cfg.skooti_audience,
      }
    end
    # getgrocery is a SECOND operator — its alcohol age-gate asks the broker for
    # the age_over_18 claim. Used by the two-server test harness; a standing
    # production allow-list entry is a follow-up, so in production it registers
    # only when KIOSK_PROVE_GETGROCERY_SECRET is explicitly set.
    if (gg = cfg.getgrocery_secret.presence)
      entries["getgrocery"] = {
        secret:        gg,
        callback_host: cfg.getgrocery_callback_host,
        audience:      cfg.getgrocery_audience,
      }
    end
    entries
  end

  # Constant-time-ish comparison so the secret check does not leak length/prefix
  # via timing. Rack::Utils.secure_compare if available, else a manual fallback.
  def secure_compare(a, b)
    require "rack/utils"
    Rack::Utils.secure_compare(a.to_s, b.to_s)
  rescue LoadError, ArgumentError
    return false unless a.to_s.bytesize == b.to_s.bytesize

    res = 0
    a.to_s.bytes.zip(b.to_s.bytes) { |x, y| res |= (x ^ y) }
    res.zero?
  end
end
