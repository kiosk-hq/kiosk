# frozen_string_literal: true

require_relative 'pow/version'
require_relative 'pow/blake2b'

module Kiosk
  # The base of every Kiosk proof-of-work backend. A backend is a module under
  # Kiosk::Pow that defines NAME, .params and .verify(salt:, params:, nonce:),
  # and can define .valid_params?. kiosk-reputation finds it by its NAME.
  # README.md, "How to add a backend", gives the steps.
  module Pow
    # One key of a wire object. Parsed JSON has String keys; Ruby callers use Symbols.
    def self.param(hash, key) = hash[key] || hash[key.to_s]
  end
end
