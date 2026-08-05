# frozen_string_literal: true

require "uri"

# OperatorRegistry — the broker's intake trust model (design §4.7). prove.my only
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
#   callback_host — the ONLY host prove.my will POST a callback to for this
#                   operator (host allow-list — an SSRF guard). The intake's
#                   callback_url must resolve to this host or the request is
#                   rejected. In the demo the operator host varies by port, so the
#                   callback host is read from env (KIOSK_PROVE_<OP>_CALLBACK_HOST).
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

  # The static demo registry. skooti and getgrocery are the two pre-registered
  # operators.
  #   - secret: shared bearer; env-overridable, else a fixed demo default.
  #   - callback_host: the operator host prove.my may call back; env-set by the
  #     two-server harness (which knows the operator's host:port), else localhost.
  def registry
    {
      "skooti" => {
        secret:        ENV.fetch("KIOSK_PROVE_SKOOTI_SECRET", "prove-skooti-demo-shared-secret"),
        callback_host: ENV.fetch("KIOSK_PROVE_SKOOTI_CALLBACK_HOST", "127.0.0.1"),
      },
      # getgrocery is a SECOND operator — its alcohol age-gate asks the broker
      # for the age_over_18 claim. Registered for the two-server test harness;
      # a standing deploy allow-list entry is a follow-up.
      "getgrocery" => {
        secret:        ENV.fetch("KIOSK_PROVE_GETGROCERY_SECRET", "prove-getgrocery-demo-shared-secret"),
        callback_host: ENV.fetch("KIOSK_PROVE_GETGROCERY_CALLBACK_HOST", "127.0.0.1"),
      },
    }
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
