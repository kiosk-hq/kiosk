# frozen_string_literal: true

Rails.configuration.x.proveli.issuer     = ENV.fetch('KIOSK_PROVELI_ISSUER')
Rails.configuration.x.proveli.public_url = ENV.fetch('PROVELI_PUBLIC_URL', nil)
Rails.configuration.x.proveli.key_pem    = ENV.fetch('PROVELI_KEY_PEM')
# An operator is served once it has a secret; the broker calls back only its host.
operators = %w[skooti getgrocery].to_h do |operator|
  prefix = "KIOSK_PROVELI_#{operator.upcase}"
  [operator, { secret: ENV.fetch("#{prefix}_SECRET", nil),
               callback_host: ENV.fetch("#{prefix}_CALLBACK_HOST", nil),
               audience: ENV.fetch("#{prefix}_AUDIENCE", operator) }]
end
Rails.configuration.x.proveli.operators = operators.select { |_, operator| operator[:secret] }
