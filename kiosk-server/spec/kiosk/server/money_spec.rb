# frozen_string_literal: true

RSpec.describe Kiosk::Server::Money do
  it 'formats minor units in the major unit of the currency' do
    expect([described_class.format(5000, 'eur'), described_class.format(7, 'usd'),
            described_class.format(500, 'jpy'), described_class.format(1234, 'kwd')])
      .to eq(['50.00 EUR', '0.07 USD', '500 JPY', '1.234 KWD'])
  end

  it 'parses an amount a person types into minor units' do
    expect([described_class.parse('50', 'eur'), described_class.parse(' 12.5 ', 'eur'),
            described_class.parse('500', 'jpy'), described_class.parse('0', 'eur')])
      .to eq([5000, 1250, 500, 0])
  end

  it 'refuses text that is not an amount with the decimals of the currency' do
    expect(['lots', '-5', '1.005', '1.', '.5', ''].map { |text| described_class.parse(text, 'eur') }
             .push(described_class.parse('1.5', 'jpy'))).to all(be_nil)
  end
end
