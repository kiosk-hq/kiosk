# kiosk-kyc-prove

Prove KYC broker adapter for [Kiosk](https://kiosk.tech). Implements
`Kiosk::KycProviders::Base` against the Prove anonymizing broker.

## Install

```ruby
gem "kiosk-kyc-prove"
```

## Configure

Register with the broker first: it holds your operator id, your intake secret
and the host your callback lives on.

```ruby
require "kiosk/kyc_providers/prove"

Kiosk.configure do |c|
  c.kyc_claims   = %w[age_over_18]
  c.kyc_provider = Kiosk::KycProviders::Prove.new(operator_id: "acme", intake_secret: ENV.fetch("PROVE_SECRET"),
                                                  public_key: ENV.fetch("PROVE_PUBLIC_KEY_PEM"))
end
```

`public_key` is the broker's Ed25519 public key, which it serves at
`<url>/prove_key.pem`. The engine checks each attestation against that key,
against the broker's issuer and against your operator id as the audience.

kiosk-server then serves `request_kyc` and the broker's callback. The adapter:

- opens a verification at `POST <broker>/verifications`, authenticated by the
  intake secret, asking for the attribute names in `kyc_claims`;
- raises `Kiosk::KycProviders::Unavailable` when the broker refuses, cannot be
  reached, or answers without `request_id`, `verification_url` and `nonce`;
- accepts only attestations whose `operator` claim is your operator id.

`Prove.new` talks to the hosted broker at `Prove::HOSTED`
(`https://kyc.demo.kiosk.tech`); pass `url:` for another one. The issuer is the
broker's URL; pass `issuer:` when the broker signs another one.

## License

Apache-2.0. See `LICENSE.txt`.
