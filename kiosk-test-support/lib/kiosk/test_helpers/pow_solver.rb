# frozen_string_literal: true

module Kiosk
  module TestHelpers
    # The solver for a proof-of-work challenge. kiosk-pow-equihash ships the one
    # solver here, and the host's bundle brings that gem.
    module PowSolver
      def self.for(challenge)
        alg = challenge['alg']
        raise ArgumentError, "The origin asks for a #{alg.inspect} proof of work. Wire solves only Equihash." unless alg == 'equihash'

        require 'kiosk/pow/equihash/solver'
        Kiosk::Pow::Equihash
      rescue LoadError
        raise LoadError, "Wire solves Equihash tolls with kiosk-pow-equihash. Add gem 'kiosk-pow-equihash' to the Gemfile."
      end
    end
  end
end
