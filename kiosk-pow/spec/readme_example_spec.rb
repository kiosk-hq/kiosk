# frozen_string_literal: true

require 'spec_helper'

# The example backend of README.md, "2. Define the module", as written.
eval(File.read(File.expand_path('../README.md', __dir__))[/^### 2\. Define the module\n.*?^```ruby\n(.*?)^```/m, 1], # rubocop:disable Security/Eval -- runs the README's own example
     binding, 'README.md')

RSpec.describe 'Kiosk::Pow::Example' do
  subject(:example) { Kiosk::Pow.const_get(:Example) }

  let(:salt)   { 'salt'.b }
  let(:params) { { bits: 4 } }
  let(:value)  { (0..).find { |n| Kiosk::Pow::Blake2b.digest256(salt + [n].pack('Q<')).unpack1('B*').start_with?('0000') } }

  it 'accepts a proof whose nonce has Symbol keys, as kiosk-server parses the Kiosk-PoW header' do
    expect(example.verify(salt:, params:, nonce: { value: })).to be(true)
  end

  it 'refuses a proof that misses the target' do
    expect(example.verify(salt:, params: { bits: 256 }, nonce: { value: })).to be(false)
  end

  [nil, true, false, 7, 'text', [1, 2], { value: 'seven' }, { value: -1 }].each do |nonce|
    it "returns false for the nonce #{nonce.inspect}" do
      expect(example.verify(salt:, params:, nonce:)).to be(false)
    end
  end
end
