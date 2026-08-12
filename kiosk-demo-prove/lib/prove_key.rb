# frozen_string_literal: true

require "openssl"
require "jwt"

# ProveKey — the broker's RSA issuer key ("the ProveKey"). This is the key each
# operator TRUSTS once (skooti sets c.kyc_public_key = ProveKey.public_key). The
# broker signs every anonymized claim with it; the operator's
# Kiosk::Server::KycVerifier accepts the claim because this broker is its configured
# c.kyc_issuer and the signature verifies against this key.
#
# Fixed dev RSA-2048 keypair — stable across processes so the Rails server (which
# loads this at boot) and the two-server demo harness (which pins the same PEM
# into skooti's config) share ONE signing key. This is the direct analogue of
# skooti's retired StubKyc, extracted into the standalone broker.
#
# In production: replace DEV_PRIVATE_PEM with a secrets-manager lookup / an
# env-loaded PEM and rotate; the shape (ProveKey.public_key / ProveKey.mint)
# stays identical. Broker compromise = trust root (design §4 residual risk).
#
#   ProveKey.public_key        → PEM string (operators pin this)
#   ProveKey.mint(...)         → compact RS256 JWS (posted to the operator callback)
#   ProveKey.issuer            → the `iss` value operators configure as c.kyc_issuer
module ProveKey
  module_function

  # (The issuer identity string and its deploy-origin default now live in
  # config/environments/*.rb — K-672; see `issuer` below.)

  # Fixed dev RSA-2048 keypair — stable for the demo. DO NOT use in production.
  # Generated once: `ruby -ropenssl -e "puts OpenSSL::PKey::RSA.new(2048).to_pem"`
  DEV_PRIVATE_PEM = <<~PEM
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEAyOq6o7Dt2ykoGBW6UzziWfECwkuStu2KStpfm/pVnVdJVY9G
    hew+Qt4kRNLfK86UdeEG7+4umEPQ0juXdu/hNtAVbvY6PgHhdupe9+m/Z4EEeoxE
    U/tM9IMIf4G2ji2Zk5UG+kCMu0+QrZQneCw2TLCrJn1y4T8nSNgbnKYfMnM4WeWh
    L483rPC2HIv1ItiOq7buj/iDGhRdLuZxQVA8uqkWGsGoqJ8lDLvY/w5fmcQo2w0T
    cDG0IBzG2Y1VYUfke86Vu1WllElyGQqss+/YH6bhui994FvcATQYtonaBqzLg/iL
    Bl5n1WkM3hZTLnC3mJlbKpnPdQ1vubRI8w8d+wIDAQABAoIBAEJSZai6M1IIjHEi
    3v4yF1/sNGZxru0OjXt3CV+CK7fEA/On13ZGzSiijqNfXobl6tDcpr8VxzDBFhIH
    1NBQj+3Zk3Gs+v3T/hqUdCPu951Rk+pmGfoE9tqx1GDOrzXQrKTwaTy7iRkdwxrh
    UIQVSBlZqi2K9JyRDcU4fSjhF2Q92c1nKREK3LYzC+eshhxKm1+tScOLUO95tWfG
    lbk3SVDcURv/a4WcDdb9m8QCZkSA5T16wAOXil0mz7qiJZPNXLhHfaTVX5ftdv51
    BOJCn1m5oOm5afVPq0AShspBcFuZfxmUQYqPZAPTvHSQCj3eD4MwAhVVwcYjRXVK
    d+835F0CgYEA5Cq4lxOldcDu6OfkfWYXoJXgavQ73RKf81kKn1aakn6RHLU+ElZ9
    u1GRC/mCKUSFPvKJcNJFdl8G+opZQr9Q9s7uD5EwW8qtlIjP3k6rnujzS8XAOCwm
    vv7AU0VUDdBw35RQLvfbI+h8oykEwPUyHFS7JuIDOWLlRzNO2Jv/LB0CgYEA4W0J
    NsQpozymNwk1VIvzIDJiZIYTIkiIB2MDwg/zFJkxL5KO0SONj1lqzJ+054Rh8B9Q
    tDQNxBwJDITDZ07RM/Vs/RZjsWv4PRulW2BnIYlh5cF5ykQbc588pYMZhSzGYIrl
    qV9/AR9wDqglgczAX8NqRKs78jzEzZh8D9LoZvcCgYEAsXV4tCgXnIo+Ru91CwMI
    hWGMdiMXHE6MERzD4kHdXusJuiZM7L5QdAxwn7ujvK0KZXcF5rXkSLiIGPzZh8x9
    EDjJd1oZHot4jfoKkoDlgmb0M47OfeH5ELvaoeleApCH+ZzE8ILd8gO0TMJubBVI
    sDhGh2tpzoxYfxQs0tQhlxECgYBbn2KoVNCLnWH9aou3gm5d/ryJGQl73LkVL4Re
    gvcMvzsDl/DeRjIKOpCy/JKdquvXmhLGO4YA2FhBM1Dsk1dqY+1ZbJk2iqjJxYvO
    +P7R3bHhnWKv+ECkHOucZg2gWFOE989iqQLI5Qs5mdQszpi+E4IEyQhDa7mdysVZ
    9SIqfwKBgQC29U9berHw/oJi5etACTndt5jLOLSml5U32l6v29z4JTSMLNzZWUve
    zcRZa4NFh0Dra4cRa06k7YkWvZU+njKqEd7gJKevN1EQiXF755GWXsf1riGRDR98
    +ITZ7IK/tVGfJqfMXd2LEaGKBJb9TtlmQSu3kSzlnw5gbNtLZ7u+LA==
    -----END RSA PRIVATE KEY-----
  PEM

  # The `iss` the broker stamps into every claim. Operators set c.kyc_issuer
  # to the SAME value (their KycVerifier compares the minted `iss` against it);
  # both sides default to the registered deploy origin kyc.demo.kiosk.tech and
  # the two-server harnesses pin a matching value on both sides. Configured per
  # environment (KIOSK_PROVE_ISSUER, read in config/environments/*.rb — K-672).
  def issuer
    Rails.configuration.x.prove.issuer
  end

  def keypair
    @keypair ||= OpenSSL::PKey::RSA.new(prove_key_pem)
  end

  # Allow an env-loaded PEM to override the baked-in dev key (production /
  # rotation), else use the fixed dev key.
  def prove_key_pem
    ENV["PROVE_KEY_PEM"] || DEV_PRIVATE_PEM
  end
  private_class_method :prove_key_pem

  # The RSA public key PEM — operators pin this as c.kyc_public_key.
  def public_key
    keypair.public_key.to_pem
  end

  # Mint a signed, anonymized, per-request claim. This is the heart of the
  # callback: the JWS the operator's KycVerifier accepts.
  #
  # The claim binds to (subject + operator + request):
  #   sub        — the operator's user_id for the requesting agent (KycVerifier
  #                rejects a claim whose sub != the authenticated agent — the
  #                cross-subject/IssuedKycJwsTheft defense, unchanged).
  #   iss        — issuer (operators configure this as c.kyc_issuer).
  #   level      — "verified" (KycVerifier requires this literal).
  #   attributes — the granted anonymized booleans, e.g. {age_over_18:true,
  #                licence_a:true}. Only booleans — never DOB/licence number.
  #   operator   — the operator_id the claim is addressed to (the human-readable
  #                broker handle; retained for the operator's callback correlation
  #                and logging).
  #   aud        — the OPERATOR-BINDING audience the claim is minted FOR. The
  #                operator's engine Kiosk::Server::KycVerifier REJECTS any claim
  #                whose `aud` != its configured `kyc_audience` — so a claim minted
  #                for operator A is rejected at operator B AT THE WIRE (not merely
  #                by a demo's own callback). Defaults to `operator` when the
  #                operator did not declare a distinct audience.
  #   request_id — the broker request this claim answers (callback correlation).
  #   nonce      — echoes the request nonce (callback anti-replay).
  #   iat/exp    — short-lived (default 1h).
  #
  # @return [String] compact RS256 JWS
  def mint(subject:, operator:, attributes:, request_id:, nonce:, audience: nil, ttl: 3600)
    now = Time.now.to_i
    JWT.encode(
      {
        sub:        subject.to_s,
        level:      "verified",
        iss:        issuer,
        operator:   operator.to_s,
        aud:        (audience.nil? || audience.to_s.empty? ? operator.to_s : audience.to_s),
        request_id: request_id.to_s,
        nonce:      nonce.to_s,
        attributes: attributes,
        iat:        now,
        exp:        now + ttl.to_i,
      },
      keypair, "RS256",
    )
  end
end
