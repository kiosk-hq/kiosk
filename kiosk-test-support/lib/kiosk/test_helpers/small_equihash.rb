# frozen_string_literal: true

require 'kiosk/pow/equihash'

module Kiosk
  module TestHelpers
    # Require this from test setup only. It makes the Equihash default params
    # n=96 k=5, so a registration in a test solves in about 0.2 s, not 10 s.
    # Params passed explicitly are unchanged.
    module SmallEquihash
      PARAMS = { n: 96, k: 5 }.freeze

      def params(n: PARAMS[:n], k: PARAMS[:k]) = super # rubocop:disable Naming/MethodParameterName -- the Equihash parameter names.
    end
  end
end

Kiosk::Pow::Equihash.singleton_class.prepend(Kiosk::TestHelpers::SmallEquihash)
