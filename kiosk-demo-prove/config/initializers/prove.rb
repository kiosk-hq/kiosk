# frozen_string_literal: true

Rails.configuration.x.prove.issuer     = ENV.fetch('KIOSK_PROVE_ISSUER')
Rails.configuration.x.prove.public_url = ENV.fetch('PROVE_PUBLIC_URL', nil)
Rails.configuration.x.prove.key_pem    = ENV.fetch('PROVE_KEY_PEM')
# An operator is served once it has a secret; the broker calls back only its host.
operators = %w[skooti getgrocery].to_h do |operator|
  prefix = "KIOSK_PROVE_#{operator.upcase}"
  [operator, { secret: ENV.fetch("#{prefix}_SECRET", nil),
               callback_host: ENV.fetch("#{prefix}_CALLBACK_HOST", nil),
               audience: ENV.fetch("#{prefix}_AUDIENCE", operator) }]
end
Rails.configuration.x.prove.operators = operators.select { |_, operator| operator[:secret] }
