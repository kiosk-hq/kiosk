# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

RSpec.describe Kiosk::UuidCheck do
  describe '.valid?' do
    it 'accepts every id a Postgres gen_random_uuid() hands back' do
      ids = Array.new(200) { SecureRandom.uuid }

      expect(ids.reject { |id| described_class.valid?(id) }).to be_empty
    end

    it 'accepts an upper-case spelling of the canonical form' do
      expect(described_class.valid?('3F0C1A2E-4B5D-6E7F-8A9B-0C1D2E3F4A5B')).to be(true)
    end

    it 'rejects non-String junk instead of raising' do
      expect([nil, 12_345, { 'a' => 1 }, [], :sym].map { |v| described_class.valid?(v) })
        .to all(be(false))
    end

    it 'anchors the whole string, so padded and multi-line values are rejected' do
      id = SecureRandom.uuid

      expect(described_class.valid?(" #{id} ")).to be(false)
      expect(described_class.valid?("#{id}\n#{id}")).to be(false)
    end

    it 'rejects the non-canonical spellings Postgres itself would accept' do
      id = SecureRandom.uuid

      expect(described_class.valid?(id.delete('-'))).to be(false)
      expect(described_class.valid?("{#{id}}")).to be(false)
      expect(described_class.valid?("urn:uuid:#{id}")).to be(false)
    end
  end
end
