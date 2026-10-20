# frozen_string_literal: true

require 'spec_helper'

# Every vector is Python's hashlib.blake2b(data, digest_size=32).hexdigest().
RSpec.describe Kiosk::Pow::Blake2b do
  describe '.digest256' do
    def hex(input) = described_class.digest256(input).unpack1('H*')

    # The first 251 byte values, repeated: no block boundary falls on a run of zeros.
    def pattern(length) = Array.new(length) { it % 251 }.pack('C*')

    it 'matches hashlib for empty input' do
      expect(hex(''.b)).to eq('0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8')
    end

    it "matches hashlib for 'abc'" do
      expect(hex('abc')).to eq('bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319')
    end

    it "matches hashlib for 'hello'" do
      expect(hex('hello')).to eq('324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf')
    end

    it 'matches hashlib for the Cuckatoo29 header (76 zero bytes + LE32(20))' do
      expect(hex("#{"\x00" * 76}#{[20].pack('V')}".b))
        .to eq('770129fe760558276ee7f431209beaf98f8607868c3063160e0d18fab03988b8')
    end

    {
      127 => 'f2fe67ff342e21b8f45e8f2e0bcd1d9243245d50ee6c78042e9c491388791c72',
      128 => 'c3582f71ebb2be66fa5dd750f80baae97554f3b015663c8be377cfcb2488c1d1',
      129 => 'f7f3c46ba2564ff4c4c162da1f5b605f9f1c4aa6a20652a9f9a337c1a2f5b9c9',
      256 => '582f782226018ec33076bd8d1c42413530ac7e1126260ffc0f306ba3befc3f24',
      336 => '7db53929eb557ab66fe84f8a30939425280b3bda0cdc69e6e4fead672d353718'
    }.each do |length, digest|
      it "matches hashlib for #{length} bytes, either side of a 128-byte block" do
        expect(hex(pattern(length))).to eq(digest)
      end
    end

    it 'returns 32 raw bytes' do
      expect(described_class.digest256('x').bytesize).to eq(32)
    end

    it 'changes with input' do
      expect(described_class.digest256('a')).not_to eq(described_class.digest256('b'))
    end
  end
end
