# frozen_string_literal: true

Rails.configuration.x.prove.issuer     = ENV.fetch("KIOSK_PROVE_ISSUER")
Rails.configuration.x.prove.public_url = ENV["PROVE_PUBLIC_URL"]
Rails.configuration.x.prove.key_pem    = ENV.fetch("PROVE_KEY_PEM")
# An operator is served once it has a secret; the broker calls back only its host.
Rails.configuration.x.prove.operators = %w[skooti getgrocery].to_h { |operator|
  prefix = "KIOSK_PROVE_#{operator.upcase}"
  [operator, { secret:        ENV["#{prefix}_SECRET"],
               callback_host: ENV["#{prefix}_CALLBACK_HOST"],
               audience:      ENV.fetch("#{prefix}_AUDIENCE", operator) }]
}.select { |_, operator| operator[:secret] }
