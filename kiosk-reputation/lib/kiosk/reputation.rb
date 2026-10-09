# frozen_string_literal: true

require "kiosk/reputation/version"
require "kiosk/reputation/backends"
require "kiosk/reputation/challenge"
require "kiosk/reputation/factors"
require "kiosk/reputation/policy"
require "kiosk/reputation/backoff_store"
require "kiosk/reputation/policies/rate_and_reputation"
require "kiosk/reputation/policies/backoff"

module Kiosk
  # Policy and wire-challenge layer for proof of work, independent of any PoW
  # algorithm. {Challenge} is stateless: the caller keeps the spent-id set.
  module Reputation
  end
end
