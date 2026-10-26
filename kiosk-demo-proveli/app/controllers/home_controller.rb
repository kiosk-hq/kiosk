# frozen_string_literal: true

# What this broker is: a KYC issuer that hands an operator only the booleans it
# asked for. It serves no Kiosk HTTP API.
class HomeController < ApplicationController
  def index
    @pending = ProveliRequest.pending.count
    @confirmed = ProveliRequest.confirmed.count
  end
end
