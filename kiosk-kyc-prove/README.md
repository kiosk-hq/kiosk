# kiosk-kyc-prove

Prove KYC broker adapter for [Kiosk](https://kiosk.tech). Implements
`Kiosk::KycProviders::Base` against the Prove anonymizing broker.

## Install

> **Not on RubyGems yet** — so the `gem` line carries `github: "kiosk-hq/kiosk"`. Publication status and the canonical install are stated once, in the monorepo README's [Install](https://github.com/kiosk-hq/kiosk#install) section.

```ruby
gem "kiosk-kyc-prove", github: "kiosk-hq/kiosk"
```

## Configure

Register with the broker first: it holds your operator id, your intake secret,
the host your callback lives on and the audience it mints attestations for.

```ruby
require "kiosk/kyc_providers/prove"

Kiosk.configure do |c|
  c.kyc_provider   = Kiosk::KycProviders::Prove.new(operator_id: "acme", intake_secret: ENV.fetch("PROVE_SECRET"))
  c.kyc_claims     = %w[age_over_18]
  c.kyc_issuer     = Kiosk::KycProviders::Prove::HOSTED
  c.kyc_public_key = ENV["PROVE_PUBLIC_KEY_PEM"]
  c.kyc_audience   = "acme"
end
```

kiosk-server then serves `request_kyc` and the broker's callback. The adapter:

- opens a verification at `POST <broker>/verifications`, authenticated by the
  intake secret, asking for the claims in the broker's vocabulary
  (`licence_a` is `licence_category:A` there);
- raises `Kiosk::KycProviders::Unavailable` when the broker refuses, cannot be
  reached, or answers without `request_id`, `verification_url` and `nonce`;
- accepts only attestations whose `operator` claim is your operator id.

`Prove.new` talks to the hosted broker at `Prove::HOSTED`
(`https://kyc.demo.kiosk.tech`); pass `url:` for another one.

## License

Apache-2.0. See `LICENSE.txt`.
