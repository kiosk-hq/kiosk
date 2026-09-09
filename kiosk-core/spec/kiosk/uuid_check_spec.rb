# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "json"

RSpec.describe Kiosk::UuidCheck do
  describe ".valid?" do
    it "accepts every id a Postgres gen_random_uuid() hands back" do
      ids = Array.new(200) { SecureRandom.uuid }

      expect(ids.reject { |id| described_class.valid?(id) }).to be_empty
    end

    it "accepts an upper-case spelling of the canonical form" do
      expect(described_class.valid?("3F0C1A2E-4B5D-6E7F-8A9B-0C1D2E3F4A5B")).to be(true)
    end

    it "rejects non-String junk instead of raising" do
      expect([nil, 12_345, { "a" => 1 }, [], :sym].map { |v| described_class.valid?(v) })
        .to all(be(false))
    end

    it "anchors the whole string, so padded and multi-line values are rejected" do
      id = SecureRandom.uuid

      expect(described_class.valid?(" #{id} ")).to be(false)
      expect(described_class.valid?("#{id}\n#{id}")).to be(false)
    end

    it "rejects the non-canonical spellings Postgres itself would accept" do
      id = SecureRandom.uuid

      expect(described_class.valid?(id.delete("-"))).to be(false)
      expect(described_class.valid?("{#{id}}")).to be(false)
      expect(described_class.valid?("urn:uuid:#{id}")).to be(false)
    end
  end

  describe "JSON_SCHEMA_PATTERN" do
    # The declared contract and the runtime guard are two spellings of one
    # shape, so they must accept and reject the same strings. A drift here is
    # an origin publishing an `input_schema` its own handler disagrees with.
    it "accepts and rejects exactly what PATTERN does" do
      re = Regexp.new(described_class::JSON_SCHEMA_PATTERN)
      candidates =
        Array.new(200) { SecureRandom.uuid } +
        Array.new(50) { SecureRandom.uuid.delete("-") } +
        ["", "not-a-uuid", "3F0C1A2E-4B5D-6E7F-8A9B-0C1D2E3F4A5B",
         "{#{SecureRandom.uuid}}", "urn:uuid:#{SecureRandom.uuid}"]

      disagreements = candidates.reject { |c| re.match?(c) == described_class.valid?(c) }

      expect(disagreements).to be_empty
    end

    it "is a JSON string, so a descriptor can carry it verbatim" do
      expect(JSON.parse(JSON.generate(described_class::JSON_SCHEMA_PATTERN)))
        .to eq(described_class::JSON_SCHEMA_PATTERN)
    end
  end
end
