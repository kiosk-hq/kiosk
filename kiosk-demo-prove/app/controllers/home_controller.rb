# frozen_string_literal: true

# What this broker is: a KYC issuer that hands an operator only the booleans it
# asked for. It serves no Kiosk HTTP API.
class HomeController < ApplicationController
  def index
    @pending = ProveRequest.pending.count
    @confirmed = ProveRequest.confirmed.count
  end
end
