# kiosk-kyc-prove

Prove KYC broker adapter for [Kiosk](https://kiosk.tech). Implements
`Kiosk::KycProviders::Base` against the Prove anonymizing broker.

## Install

```ruby
gem "kiosk-kyc-prove"
```

## Configure

The broker holds your operator id, your intake secret and the host that your
callback lives on. The hosted broker at `https://kyc.demo.kiosk.tech` is a demo:
it serves only the demo operators `skooti` and `getgrocery`, which its own
configuration names, and no other operator can register with it. To use the
adapter, run your own broker, the `kiosk-demo-prove` application of this
repository:

1. Add your operator id to the list in its `config/initializers/prove.rb`.
2. Set `KIOSK_PROVE_<OPERATOR>_SECRET` (your intake secret) and
   `KIOSK_PROVE_<OPERATOR>_CALLBACK_HOST` (the host of your origin) on the
   broker.
3. Give the adapter the same secret and the broker's URL:

```ruby
require "kiosk/kyc_providers/prove"

Kiosk.configure do |c|
  c.kyc_claims   = %w[age_over_18]
  c.kyc_provider = Kiosk::KycProviders::Prove.new(operator_id: "acme",
                                                  intake_secret: ENV.fetch("KIOSK_PROVE_INTAKE_SECRET"),
                                                  url: ENV.fetch("KIOSK_PROVE_BROKER_URL"),
                                                  public_key: ENV.fetch("KIOSK_PROVE_PUBLIC_KEY_PEM"))
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

Without `url:`, `Prove.new` talks to the hosted demo broker at `Prove::HOSTED`
(`https://kyc.demo.kiosk.tech`). The issuer is the
broker's URL; pass `issuer:` when the broker signs another one.

## License

Apache-2.0. See `LICENSE.txt`.
