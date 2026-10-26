# frozen_string_literal: true

module Kiosk
  module Server
    # An amount in minor units (cents) as a person reads and types it: in the
    # currency's major unit, with the ISO 4217 number of decimals.
    module Money
      # ISO 4217 currencies whose minor unit is not 1/100. Every other code has two decimals.
      DECIMALS = {
        'bif' => 0, 'clp' => 0, 'djf' => 0, 'gnf' => 0, 'isk' => 0, 'jpy' => 0, 'kmf' => 0,
        'krw' => 0, 'pyg' => 0, 'rwf' => 0, 'ugx' => 0, 'uyi' => 0, 'vnd' => 0, 'vuv' => 0,
        'xaf' => 0, 'xof' => 0, 'xpf' => 0,
        'bhd' => 3, 'iqd' => 3, 'jod' => 3, 'kwd' => 3, 'lyd' => 3, 'omr' => 3, 'tnd' => 3,
        'clf' => 4, 'uyw' => 4
      }.freeze

      module_function

      # `5000, 'eur'` → `"50.00 EUR"`.
      def format(cents, currency) = "#{amount(cents, currency)} #{currency.upcase}"

      # `5000, 'eur'` → `"50.00"`.
      def amount(cents, currency)
        decimals = decimals(currency)
        whole, fraction = cents.divmod(10**decimals)
        decimals.zero? ? whole.to_s : "#{whole}.#{fraction.to_s.rjust(decimals, '0')}"
      end

      # `"50", 'eur'` → `5000`. Nil for text that is not an amount with at most the currency's decimals.
      def parse(text, currency)
        decimals = decimals(currency)
        fraction = decimals.zero? ? '' : "(?:\\.(\\d{1,#{decimals}}))?"
        match = /\A(\d+)#{fraction}\z/.match(text.strip) or return nil

        (match[1].to_i * (10**decimals)) + match[2].to_s.ljust(decimals, '0').to_i
      end

      def decimals(currency) = DECIMALS.fetch(currency.downcase, 2)
    end
  end
end
