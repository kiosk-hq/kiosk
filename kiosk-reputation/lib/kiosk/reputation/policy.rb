# frozen_string_literal: true

module Kiosk
  module Reputation
    # Base policy: never challenges. Providers subclass it.
    class Policy
      # The gate calls it with `identity:`, `verb:` and `factors:`. `verb` is the
      # coarse CALL KIND: :query, :run or :pay (a `kind :action` handler arrives as :run).
      # @return [Hash{alg: String, params: Hash, count: Integer}, nil] nil serves without challenge; `count` defaults to 1
      def challenge_for(**)
        nil
      end
    end
  end
end
