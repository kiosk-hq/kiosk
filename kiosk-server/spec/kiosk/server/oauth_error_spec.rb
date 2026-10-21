# frozen_string_literal: true

# The OAuth error object of the `/oauth/*` endpoints: a closed vocabulary, and
# 401 for a failed client authentication only (RFC 6749 Section 5.2).
RSpec.describe Kiosk::Server::OauthError do
  it 'answers {error, error_description}, 401 for invalid_client and 400 for every other code' do
    expect(described_class.new(:invalid_client, 'sign again').to_h)
      .to eq(error: 'invalid_client', error_description: 'sign again')
    expect(described_class::CODES.index_with { described_class.new(it, 'd').status })
      .to eq(described_class::CODES.index_with { it == 'invalid_client' ? 401 : 400 })
  end

  it 'refuses a code outside the vocabulary' do
    expect { described_class.new(:server_error, 'd') }.to raise_error(ArgumentError, /server_error/)
  end
end
