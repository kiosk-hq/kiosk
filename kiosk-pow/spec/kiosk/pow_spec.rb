# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Kiosk::Pow, '.param' do
  it 'reads a Symbol key' do
    expect(described_class.param({ n: 168 }, :n)).to eq(168)
  end

  it 'reads the String key that parsed JSON carries' do
    expect(described_class.param({ 'n' => 168 }, :n)).to eq(168)
  end

  it 'answers nil for a missing key' do
    expect(described_class.param({}, :n)).to be_nil
  end
end
